// Generates containerd's RuntimeDefault seccomp profile as resolved for the desktop container's
// capabilities, amd64 and arm64 merged, plus the syscalls given as arguments (README, "Seccomp profile").
//
// profile.go is containerd v2.3.5's contrib/seccomp/seccomp_default.go with: package main, no build
// tag, runtime.GOARCH replaced by goarch, the kernel >= 4.8 check taken as true. On Linux:
//
//	go run . > ../../tests/fixtures/runtime-default-seccomp.json
//	go run . pivot_root > ../desktop.json
package main

import (
	"encoding/json"
	"os"

	"github.com/opencontainers/runtime-spec/specs-go"
)

var goarch string

func main() {
	caps := []string{"CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_FSETID", "CAP_FOWNER", "CAP_MKNOD", "CAP_NET_RAW",
		"CAP_SETGID", "CAP_SETUID", "CAP_SETFCAP", "CAP_SETPCAP", "CAP_NET_BIND_SERVICE", "CAP_SYS_CHROOT",
		"CAP_KILL", "CAP_AUDIT_WRITE", "CAP_SYS_ADMIN", "CAP_SYS_NICE"}
	sp := &specs.Spec{Process: &specs.Process{Capabilities: &specs.LinuxCapabilities{Bounding: caps}}}
	var out *specs.LinuxSeccomp
	for _, a := range []string{"amd64", "arm64"} {
		goarch = a
		p := DefaultProfile(sp)
		if out == nil {
			out = p
			continue
		}
		out.Architectures = append(out.Architectures, p.Architectures...)
		seen := map[string]bool{}
		for _, s := range out.Syscalls {
			b, _ := json.Marshal(s)
			seen[string(b)] = true
		}
		for _, s := range p.Syscalls {
			if b, _ := json.Marshal(s); !seen[string(b)] {
				out.Syscalls = append(out.Syscalls, s)
			}
		}
	}
	if extra := os.Args[1:]; len(extra) > 0 {
		out.Syscalls = append(out.Syscalls, specs.LinuxSyscall{Names: extra, Action: specs.ActAllow})
	}
	e := json.NewEncoder(os.Stdout)
	e.SetIndent("", "  ")
	e.Encode(out)
}
