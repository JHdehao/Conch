// Conch additions (not part of upstream libtailscale). Declared for C in conch_tailscale.h.

package main

//#include <errno.h>
import "C"

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"sync"
	"syscall"
	"time"

	"tailscale.com/net/netns"
)

func init() {
	// Tailscale normally pins its own sockets to the physical interface (en0) so
	// they can't loop back through its tunnel. This node has no tunnel — it runs on
	// a userspace stack inside the app — so the pinning only does harm: with a VPN
	// such as Shadowrocket on, DNS hands out the VPN's fake IPs (198.18.x.x), and
	// dialing those on en0 goes nowhere, so the control server is never reached and
	// no login link ever arrives. Let the OS route these sockets like any other app's.
	// Pinned (patches/tailscale-netns-never-bind.patch): every netmap re-applies the
	// control server's setting, which would turn binding back on for the next start.
	netns.SetNeverBindConnToInterface(log.Printf)
}

// udpFlows maps the descriptor handed to C to the function that tears its flow down.
// Needed because closing one end of a datagram socketpair doesn't wake a read on
// the other end on Darwin, so Go would never notice on its own.
var udpFlows struct {
	mu sync.Mutex
	m  map[C.int]*udpFlow
}

type udpFlow struct{ stop func() }

// conch_tailscale_dial_udp opens a UDP flow to addr ("ip:port") over the tailnet
// and returns one end of a SOCK_DGRAM socketpair: every send(2) on it becomes one
// UDP packet, and every packet that comes back is one recv(2). (tailscale_dial
// hands back a stream socket, which would merge and split datagrams.) End the flow
// with conch_tailscale_udp_close, not close(2).
//
//export conch_tailscale_dial_udp
func conch_tailscale_dial_udp(sd C.int, addr *C.char, connOut *C.int) C.int {
	s := getServer(sd)
	if s == nil {
		return C.EBADF
	}
	udp, err := s.s.Dial(context.Background(), "udp", C.GoString(addr))
	if err != nil {
		return s.recErr(err)
	}
	fds, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
	if err != nil {
		udp.Close()
		return s.recErr(err)
	}
	// On Darwin a Unix datagram can't exceed the send buffer (2 KB by default).
	for _, fd := range fds {
		syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_SNDBUF, 64<<10)
		syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_RCVBUF, 256<<10)
	}
	file := os.NewFile(uintptr(fds[1]), "conch-udp")
	local, err := net.FileConn(file) // dups the descriptor
	file.Close()
	if err != nil {
		syscall.Close(fds[0])
		udp.Close()
		return s.recErr(err)
	}

	var once sync.Once
	flow := &udpFlow{}
	flow.stop = func() {
		once.Do(func() {
			local.Close()
			udp.Close()
			udpFlows.mu.Lock()
			if udpFlows.m[C.int(fds[0])] == flow {
				delete(udpFlows.m, C.int(fds[0]))
			}
			udpFlows.mu.Unlock()
		})
	}
	stop := flow.stop
	udpFlows.mu.Lock()
	if udpFlows.m == nil {
		udpFlows.m = map[C.int]*udpFlow{}
	}
	udpFlows.m[C.int(fds[0])] = flow
	udpFlows.mu.Unlock()
	// App → tailnet.
	go func() {
		defer stop()
		buf := make([]byte, 64<<10)
		for {
			n, err := local.Read(buf)
			if err != nil {
				return
			}
			if _, err := udp.Write(buf[:n]); err != nil {
				return
			}
		}
	}()
	// Tailnet → app.
	go func() {
		defer stop()
		buf := make([]byte, 64<<10)
		for {
			n, err := udp.Read(buf)
			if err != nil {
				return
			}
			if _, err := local.Write(buf[:n]); err != nil {
				if err == syscall.ENOBUFS || err == syscall.EAGAIN {
					continue // the app is behind; drop the packet like a real network would
				}
				return
			}
		}
	}()

	*connOut = C.int(fds[0])
	return 0
}

// conch_tailscale_udp_close ends a flow from conch_tailscale_dial_udp and closes fd.
//
//export conch_tailscale_udp_close
func conch_tailscale_udp_close(fd C.int) {
	udpFlows.mu.Lock()
	flow := udpFlows.m[fd]
	delete(udpFlows.m, fd)
	udpFlows.mu.Unlock()
	if flow != nil {
		flow.stop()
	}
	syscall.Close(int(fd))
}

// conch_tailscale_set_logfd is tailscale_set_logfd with a timestamp on every line,
// each line written in one call so lines from different goroutines don't interleave.
//
//export conch_tailscale_set_logfd
func conch_tailscale_set_logfd(sd, fd C.int) C.int {
	s := getServer(sd)
	if s == nil {
		return C.EBADF
	}
	f := os.NewFile(uintptr(fd), "logfd")
	s.s.Logf = func(format string, args ...any) {
		line := time.Now().Format("15:04:05.000 ") + fmt.Sprintf(format, args...)
		if len(line) == 0 || line[len(line)-1] != '\n' {
			line += "\n"
		}
		f.WriteString(line)
	}
	return 0
}
