package doctor

import "testing"

func TestSummariseAllOK(t *testing.T) {
	checks := []Check{{Name: "docker", Status: StatusOK}, {Name: "binderfs", Status: StatusOK}}
	if got := summarise(checks); got != "all checks passed" {
		t.Fatalf("unexpected summary: %s", got)
	}
}

func TestSummariseWarnings(t *testing.T) {
	checks := []Check{{Name: "docker", Status: StatusOK}, {Name: "gpu", Status: StatusWarning}}
	if got := summarise(checks); got != "warnings detected" {
		t.Fatalf("unexpected summary: %s", got)
	}
}

func TestSummariseErrors(t *testing.T) {
	checks := []Check{{Name: "docker", Status: StatusWarning}, {Name: "binderfs", Status: StatusError}}
	if got := summarise(checks); got != "errors detected" {
		t.Fatalf("unexpected summary: %s", got)
	}
}
