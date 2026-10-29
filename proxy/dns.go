package main

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"net"
	"strings"
	"time"
)

// Query a specific DNS server for an A record directly.
//
// net.Resolver cannot be used: Go's pure resolver reads /etc/hosts first,
// and bindhosts fills hosts with `0.0.0.0 ad-domain` lines,
// so those domains resolve to 0.0.0.0 and upstream becomes unreachable.
func dnsLookup(server, host string) ([]string, error) {
	host = strings.TrimSuffix(host, ".")
	if host == "" {
		return nil, fmt.Errorf("empty host")
	}

	var id [2]byte
	if _, err := rand.Read(id[:]); err != nil {
		binary.BigEndian.PutUint16(id[:], 1)
	}

	// header
	msg := make([]byte, 0, 512)
	msg = append(msg, id[:]...)
	msg = append(msg, 0x01, 0x00) // RD=1
	msg = append(msg, 0x00, 0x01) // QDCOUNT=1
	msg = append(msg, 0x00, 0x00) // ANCOUNT
	msg = append(msg, 0x00, 0x00) // NSCOUNT
	msg = append(msg, 0x00, 0x00) // ARCOUNT

	// question
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 {
			return nil, fmt.Errorf("bad label in %q", host)
		}
		msg = append(msg, byte(len(label)))
		msg = append(msg, label...)
	}
	msg = append(msg, 0x00)
	msg = append(msg, 0x00, 0x01) // QTYPE=A
	msg = append(msg, 0x00, 0x01) // QCLASS=IN

	conn, err := net.DialTimeout("udp", server, 5*time.Second)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))

	if _, err := conn.Write(msg); err != nil {
		return nil, err
	}

	buf := make([]byte, 1500)
	n, err := conn.Read(buf)
	if err != nil {
		return nil, err
	}
	resp := buf[:n]

	if len(resp) < 12 {
		return nil, fmt.Errorf("short response")
	}
	if resp[0] != id[0] || resp[1] != id[1] {
		return nil, fmt.Errorf("id mismatch")
	}
	rcode := resp[3] & 0x0f
	if rcode != 0 {
		return nil, fmt.Errorf("rcode %d", rcode)
	}

	qd := int(binary.BigEndian.Uint16(resp[4:6]))
	an := int(binary.BigEndian.Uint16(resp[6:8]))

	p := 12
	for i := 0; i < qd; i++ {
		p = skipName(resp, p)
		p += 4
		if p > len(resp) {
			return nil, fmt.Errorf("truncated question")
		}
	}

	var ips []string
	for i := 0; i < an && p < len(resp); i++ {
		p = skipName(resp, p)
		if p+10 > len(resp) {
			break
		}
		rtype := binary.BigEndian.Uint16(resp[p : p+2])
		rdlen := int(binary.BigEndian.Uint16(resp[p+8 : p+10]))
		p += 10
		if p+rdlen > len(resp) {
			break
		}
		if rtype == 1 && rdlen == 4 { // A
			ips = append(ips, net.IP(resp[p:p+4]).String())
		}
		p += rdlen
	}
	if len(ips) == 0 {
		return nil, fmt.Errorf("no A record for %s", host)
	}
	return ips, nil
}

// skipName skips a DNS name, compression pointers included
func skipName(b []byte, p int) int {
	for p < len(b) {
		l := int(b[p])
		if l == 0 {
			return p + 1
		}
		if l&0xc0 == 0xc0 { // pointer
			return p + 2
		}
		p += 1 + l
	}
	return p
}

// lookup resolves through a fixed DNS server, bypassing hosts
func lookup(host string) ([]string, error) {
	return dnsLookup(dnsServer, host)
}
