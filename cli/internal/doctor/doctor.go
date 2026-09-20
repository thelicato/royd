package doctor

import (
	"os"
	"os/exec"
	"runtime"
	"strings"
)

type Status string

const (
	StatusOK      Status = "ok"
	StatusWarning Status = "warning"
)

type Check struct {
	Name    string
	Status  Status
	Details string
}

type Report struct {
	OS      string
	Arch    string
	Checks  []Check
	Summary string
}

func Generate() Report {
	report := Report{
		OS:   runtime.GOOS,
		Arch: runtime.GOARCH,
	}

	report.Checks = append(report.Checks, checkDocker())
	report.Checks = append(report.Checks, checkBinderFS())
	report.Checks = append(report.Checks, checkDRI())
	report.Summary = summarise(report.Checks)
	return report
}

func checkDocker() Check {
	_, err := exec.LookPath("docker")
	if err != nil {
		return Check{Name: "docker", Status: StatusWarning, Details: "docker not found in PATH"}
	}
	return Check{Name: "docker", Status: StatusOK, Details: "docker found in PATH"}
}

func checkBinderFS() Check {
	data, err := os.ReadFile("/proc/filesystems")
	if err != nil {
		return Check{Name: "binderfs", Status: StatusWarning, Details: "could not read /proc/filesystems"}
	}
	if strings.Contains(string(data), "binder") {
		return Check{Name: "binderfs", Status: StatusOK, Details: "binder filesystem advertised by kernel"}
	}
	return Check{Name: "binderfs", Status: StatusWarning, Details: "binder filesystem not advertised by kernel"}
}

func checkDRI() Check {
	_, err := os.Stat("/dev/dri")
	if err != nil {
		return Check{Name: "gpu", Status: StatusWarning, Details: "/dev/dri not present"}
	}
	return Check{Name: "gpu", Status: StatusOK, Details: "/dev/dri present"}
}

func summarise(checks []Check) string {
	for _, check := range checks {
		if check.Status != StatusOK {
			return "warnings detected"
		}
	}
	return "all checks passed"
}
