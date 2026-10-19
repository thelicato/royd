package evidence

import (
	"bytes"
	"fmt"
	"os"
	"strings"
	"testing"
	"text/template"
)

func productionTemplate(t *testing.T) *template.Template {
	t.Helper()
	source, err := os.ReadFile(os.Getenv("ROYD_CONTAINER_EVIDENCE_SCRIPT"))
	if err != nil {
		t.Fatal(err)
	}
	_, rest, found := strings.Cut(string(source), "docker inspect --format '")
	if !found {
		t.Fatal("production inspect template not found")
	}
	format, _, found := strings.Cut(rest, "' \"$container\"")
	if !found {
		t.Fatal("production inspect template is not terminated")
	}
	// Docker rejects missing map fields, unlike the default Go template mode.
	tmpl, err := template.New("docker-inspect").Option("missingkey=error").Parse(format)
	if err != nil {
		t.Fatal(err)
	}
	return tmpl
}

func inspectState() map[string]any {
	return map[string]any{
		"Name": "/mock-royd", "Id": "abc123", "Image": "sha256:image",
		"State": map[string]any{
			"Status": "created", "Running": false, "ExitCode": 0,
			"OOMKilled": false, "Error": "Docker start failed: diagnostic retained",
		},
	}
}

func TestProductionHealthTemplate(t *testing.T) {
	tmpl := productionTemplate(t)
	for _, tc := range []struct {
		name, status, health string
		running              bool
		nullHealth           bool
	}{
		{name: "created", status: "created"},
		{name: "exited", status: "exited"},
		{name: "running-without-healthcheck", status: "running", running: true},
		{name: "null-health", status: "created", nullHealth: true},
		{name: "healthy", status: "running", running: true, health: "healthy"},
		{name: "unhealthy", status: "running", running: true, health: "unhealthy"},
		{name: "starting", status: "running", running: true, health: "starting"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			data := inspectState()
			state := data["State"].(map[string]any)
			state["Status"], state["Running"] = tc.status, tc.running
			health := "none"
			if tc.nullHealth {
				state["Health"] = nil
			} else if tc.health != "" {
				state["Health"] = map[string]any{"Status": tc.health}
				health = tc.health
			}
			var output bytes.Buffer
			if err := tmpl.Execute(&output, data); err != nil {
				t.Fatal(err)
			}
			want := fmt.Sprintf("name=/mock-royd\nid=abc123\nimage=sha256:image\nstatus=%s\nrunning=%t\nexit_code=0\noom_killed=false\nerror=%s\nhealth=%s",
				tc.status, tc.running, state["Error"], health)
			if output.String() != want {
				t.Fatalf("unexpected state evidence:\n%s\nwant:\n%s", output.String(), want)
			}
		})
	}
}

func TestProductionTemplateRequiresOtherFields(t *testing.T) {
	tmpl := productionTemplate(t)
	for _, field := range []string{"Name", "Id", "Image", "State", "Status", "Running", "ExitCode", "OOMKilled", "Error", "Health.Status"} {
		t.Run(field, func(t *testing.T) {
			data := inspectState()
			if field == "Name" || field == "Id" || field == "Image" || field == "State" {
				delete(data, field)
			} else if field == "Health.Status" {
				data["State"].(map[string]any)["Health"] = map[string]any{"FailingStreak": 1}
			} else {
				delete(data["State"].(map[string]any), field)
			}
			if err := tmpl.Execute(new(bytes.Buffer), data); err == nil {
				t.Fatal("accepted missing required field")
			}
		})
	}
}
