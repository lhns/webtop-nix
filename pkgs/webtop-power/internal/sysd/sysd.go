// Package sysd lists pending systemd jobs.
package sysd

import (
	"fmt"

	"github.com/godbus/dbus/v5"
)

const (
	dest       = "org.freedesktop.systemd1"
	managerObj = "/org/freedesktop/systemd1"
	managerIf  = "org.freedesktop.systemd1.Manager"
)

// Job is a queued systemd job (ListJobs: id, unit, type, state, job path, unit path).
type Job struct {
	ID       uint32
	Unit     string
	Type     string
	State    string
	JobPath  dbus.ObjectPath
	UnitPath dbus.ObjectPath
}

// ListJobs returns the job queue from the system bus.
func ListJobs() ([]Job, error) {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	var jobs []Job
	if err := conn.Object(dest, managerObj).Call(managerIf+".ListJobs", 0).Store(&jobs); err != nil {
		return nil, fmt.Errorf("ListJobs: %w", err)
	}
	return jobs, nil
}
