// Conch additions to libtailscale (implemented in conch.go).
#ifndef CONCH_TAILSCALE_H
#define CONCH_TAILSCALE_H

// Opens a UDP flow to addr ("ip:port" or "[ipv6]:port") over the tailnet. On success
// *conn_out is a SOCK_DGRAM socket: each send() is one UDP packet, each recv() one
// packet back. Returns 0, or -1 with tailscale_errmsg set.
extern int conch_tailscale_dial_udp(int sd, const char* addr, int* conn_out);

// Ends a flow from conch_tailscale_dial_udp and closes its descriptor (use this
// instead of close(), which the Go side wouldn't notice).
extern void conch_tailscale_udp_close(int conn);

// Like tailscale_set_logfd, but each line starts with the time (HH:MM:SS.mmm).
extern int conch_tailscale_set_logfd(int sd, int fd);

#endif
