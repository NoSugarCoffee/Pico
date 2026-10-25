package cli

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/notify"
)

const deviceToken = "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0"

func register(t *testing.T, dir string) apnsRegisterOutput {
	t.Helper()
	status, stdout, stderr := runIn(dir, "apns", "register", deviceToken, "--topic", "com.example.pico", "--environment", "development", "--json")
	if status != ExitOK {
		t.Fatalf("status %d stderr %s", status, stderr)
	}
	var out apnsRegisterOutput
	if err := json.Unmarshal([]byte(stdout), &out); err != nil {
		t.Fatal(err)
	}
	if out.SchemaVersion != SchemaVersion || out.KeyID == "" {
		t.Fatalf("output %s", stdout)
	}
	return out
}

func TestAPNsRegisterStagesTheDeviceUntilActivated(t *testing.T) {
	dir := t.TempDir()
	out := register(t, dir)
	key, err := base64.StdEncoding.DecodeString(out.Key)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, notify.RegistrationFile)
	if _, err := notify.ActiveDevice(path); !errors.Is(err, notify.ErrNotRegistered) {
		t.Fatalf("registered before activation: %v", err)
	}

	status, stdout, stderr := runIn(dir, "apns", "activate", out.KeyID, "--json")
	if status != ExitOK || stdout != `{"schemaVersion":1,"ok":true}`+"\n" {
		t.Fatalf("status %d stdout %s stderr %s", status, stdout, stderr)
	}
	active, err := notify.ActiveDevice(path)
	if err != nil {
		t.Fatal(err)
	}
	if active.Token != deviceToken || active.Topic != "com.example.pico" || active.Environment != notify.Development ||
		active.KeyID != out.KeyID || string(active.Key) != string(key) || !active.RegisteredAt.Equal(fixedAt) {
		t.Errorf("active %+v", active)
	}
}

func TestAPNsReRegisteringKeepsTheActiveDeviceUntilTheNewOneActivates(t *testing.T) {
	dir := t.TempDir()
	first := register(t, dir)
	if status, _, stderr := runIn(dir, "apns", "activate", first.KeyID, "--json"); status != ExitOK {
		t.Fatal(stderr)
	}
	second := register(t, dir)
	path := filepath.Join(dir, notify.RegistrationFile)
	if active, err := notify.ActiveDevice(path); err != nil || active.KeyID != first.KeyID {
		t.Fatalf("active %+v err %v", active, err)
	}
	status, stdout, _ := runIn(dir, "apns", "activate", first.KeyID, "--json")
	if status != ExitError || !strings.Contains(stdout, `"code":"not_found"`) {
		t.Errorf("activating a stale key: status %d stdout %s", status, stdout)
	}
	if status, _, stderr := runIn(dir, "apns", "activate", second.KeyID, "--json"); status != ExitOK {
		t.Fatal(stderr)
	}
	if active, err := notify.ActiveDevice(path); err != nil || active.KeyID != second.KeyID {
		t.Errorf("active %+v err %v", active, err)
	}
}

func TestAPNsRegisterRejectsBadInput(t *testing.T) {
	cases := [][]string{
		{"apns", "register", deviceToken, "--topic", "com.example.pico", "--json"},
		{"apns", "register", "XYZ", "--topic", "com.example.pico", "--environment", "development", "--json"},
		{"apns", "register", deviceToken, "--topic", "com.example.pico", "--environment", "staging", "--json"},
		{"apns", "unregister", "--json"},
		{"apns", "activate", "--json"},
	}
	for _, args := range cases {
		status, stdout, _ := runIn(t.TempDir(), args...)
		if status != ExitError || !strings.Contains(stdout, `"code":"bad_request"`) {
			t.Errorf("%v: status %d stdout %s", args, status, stdout)
		}
	}
}

func TestAPNsRegisterReplacesAnUnreadableFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, notify.RegistrationFile)
	if err := os.WriteFile(path, []byte("{not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	out := register(t, dir)
	if status, _, stderr := runIn(dir, "apns", "activate", out.KeyID, "--json"); status != ExitOK {
		t.Fatal(stderr)
	}
	if active, err := notify.ActiveDevice(path); err != nil || active.KeyID != out.KeyID {
		t.Errorf("active %+v err %v", active, err)
	}
}

// The app decodes this file in HostEventContractTests, so both sides read the same reply shape.
func TestAPNsRegisterContractVector(t *testing.T) {
	const vectorPath = "../../testdata/contract/apns_register.json"
	if *update {
		out := register(t, t.TempDir())
		data, err := json.MarshalIndent(out, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(vectorPath, append(data, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	data, err := os.ReadFile(vectorPath)
	if err != nil {
		t.Fatal(err)
	}
	var out apnsRegisterOutput
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatal(err)
	}
	if out.SchemaVersion != SchemaVersion || out.KeyID == "" {
		t.Fatalf("vector %s", data)
	}
	key, err := base64.StdEncoding.DecodeString(out.Key)
	if err != nil || len(key) != notify.PushKeyLength {
		t.Fatalf("key %q: %v", out.Key, err)
	}
}
