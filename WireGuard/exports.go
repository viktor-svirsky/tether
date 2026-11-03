package main

// The C API WireGuardServer.swift calls. One server at a time. Strings Go returns are malloc'd and
// the caller frees them with TetherWGFree. The server key is 32 raw bytes. The device list and the
// stats are JSON messages with a version, see boundary.go, which holds the work these only wrap.

/*
#include <stdlib.h>
#include <stdint.h>
*/
import "C"

import (
	"net/netip"
	"runtime/debug"
	"sync"
	"unsafe"
)

var (
	mu     sync.Mutex
	server *Server
)

func cerr(err error) *C.char {
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

// survive turns a panic into an error message. A panic that leaves an exported function would end
// the whole app, not just the WireGuard server. Call it deferred, with the result to set.
func survive(result **C.char) {
	if r := recover(); r != nil {
		*result = C.CString(recovered(r))
	}
}

// TetherWGStart listens on host:port. Returns nil, or an error message.
//
//export TetherWGStart
func TetherWGStart(host *C.char, port C.int, privateKey *C.uint8_t) (result *C.char) {
	defer survive(&result)
	mu.Lock()
	defer mu.Unlock()
	if host == nil || privateKey == nil {
		return C.CString("no address or key")
	}
	if server != nil {
		server.Close()
		server = nil
	}
	addr, err := netip.ParseAddr(C.GoString(host))
	if err != nil {
		return cerr(err)
	}
	var key [32]byte
	copy(key[:], unsafe.Slice((*byte)(privateKey), 32))
	s, err := Start(addr, int(port), key)
	if err != nil {
		return cerr(err)
	}
	server = s
	return nil
}

//export TetherWGStop
func TetherWGStop() {
	mu.Lock()
	defer mu.Unlock()
	if server == nil {
		return
	}
	s := server
	server = nil
	// A panic that leaves here would end the whole app, see survive. There's no error to return.
	defer func() { _ = recover() }()
	s.Close()
}

// TetherWGConfigure lets in exactly the devices in a JSON configMessage. Returns nil, or an error
// message.
//
//export TetherWGConfigure
func TetherWGConfigure(message *C.char) (result *C.char) {
	defer survive(&result)
	if message == nil {
		return C.CString("no device list")
	}
	return cerr(configure(C.GoString(message)))
}

// TetherWGFreeMemory gives memory the GC has freed back to iOS. Swift calls it on a memory warning.
//
//export TetherWGFreeMemory
func TetherWGFreeMemory() { debug.FreeOSMemory() }

// TetherWGStats returns a JSON statsMessage, or nil when the server isn't running.
//
//export TetherWGStats
func TetherWGStats() (result *C.char) {
	// A panic that leaves here would end the whole app, see survive. This one is dropped on
	// purpose: Swift reads nil as no stats this round and keeps the last counters it read.
	defer func() {
		if recover() != nil {
			result = nil
		}
	}()
	js, ok := statsJSON()
	if !ok {
		return nil
	}
	return C.CString(js)
}

//export TetherWGFree
func TetherWGFree(p *C.char) { C.free(unsafe.Pointer(p)) }

func main() {}
