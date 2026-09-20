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
	StatusError   Status = "error"
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
	report := Report{OS: runtime.GOOS, Arch: runtime.GOARCH}
	report.Checks = append(report.Checks,
		checkLinux(),
		checkDocker(),
		checkDockerDaemon(),
		checkBinderFS(),
		checkCgroupV2(),
		checkPSI(),
		checkDRI(),
	)
	report.Summary = summarise(report.Checks)
	return report
}

func checkLinux() Check {
	if runtime.GOOS != "linux" {
		return Check{Name: "linux", Status: StatusError, Details: "royd runtime requires a Linux host kernel"}
	}
	return Check{Name: "linux", Status: StatusOK, Details: "Linux host detected"}
}

func checkDocker() Check {
	_, err := exec.LookPath("docker")
	if err != nil {
		return Check{Name: "docker", Status: StatusError, Details: "docker not found in PATH"}
	}
	return Check{Name: "docker", Status: StatusOK, Details: "docker found in PATH"}
}

func checkDockerDaemon() Check {
	if _, err := exec.LookPath("docker"); err != nil {
		return Check{Name: "docker-daemon", Status: StatusError, Details: "docker unavailable"}
	}
	if err := exec.Command("docker", "info").Run(); err != nil {
		return Check{Name: "docker-daemon", Status: StatusError, Details: "docker daemon is not reachable"}
	}
	return Check{Name: "docker-daemon", Status: StatusOK, Details: "docker daemon is reachable"}
}

func checkBinderFS() Check {
	data, err := os.ReadFile("/proc/filesystems")
	if err != nil {
		return Check{Name: "binderfs", Status: StatusWarning, Details: "could not read /proc/filesystems"}
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 0 && fields[len(fields)-1] == "binder" {
			return Check{Name: "binderfs", Status: StatusOK, Details: "binder filesystem advertised by kernel"}
		}
	}
	return Check{Name: "binderfs", Status: StatusError, Details: "binder filesystem not advertised by kernel"}
}

func checkCgroupV2() Check {
	if _, err := os.Stat("/sys/fs/cgroup/cgroup.controllers"); err != nil {
		return Check{Name: "cgroup-v2", Status: StatusWarning, Details: "cgroup v2 not detected"}
	}
	return Check{Name: "cgroup-v2", Status: StatusOK, Details: "cgroup v2 detected"}
}

func checkPSI() Check {
	if _, err := os.Stat("/proc/pressure/memory"); err != nil {
		return Check{Name: "psi", Status: StatusWarning, Details: "memory PSI interface not detected"}
	}
	return Check{Name: "psi", Status: StatusOK, Details: "memory PSI interface detected"}
}

func checkDRI() Check {
	_, err := os.Stat("/dev/dri")
	if err != nil {
		return Check{Name: "gpu", Status: StatusOK, Details: "/dev/dri not present; not required for the software graphics baseline"}
	}
	return Check{Name: "gpu", Status: StatusOK, Details: "/dev/dri present; host GPU mode is not enabled yet"}
}

func (report Report) HasErrors() bool {
	for _, check := range report.Checks {
		if check.Status == StatusError {
			return true
		}
	}
	return false
}

func summarise(checks []Check) string {
	hasWarning := false
	for _, check := range checks {
		if check.Status == StatusError {
			return "errors detected"
		}
		if check.Status == StatusWarning {
			hasWarning = true
		}
	}
	if hasWarning {
		return "warnings detected"
	}
	return "all checks passed"
}
