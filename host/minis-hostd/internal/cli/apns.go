package cli

import (
	"encoding/base64"
	"errors"
	"fmt"
	"io/fs"
	"net/http"
	"os"
	"path/filepath"

	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/config"
	"github.com/NoSugarCoffee/Pico/host/minis-hostd/internal/notify"
)

const (
	usageAPNsRegister   = "minis-hostd apns register <device token> --topic <bundle id> --environment development|production --json"
	usageAPNsActivate   = "minis-hostd apns activate <key id> --json"
	usageAPNsUnregister = "minis-hostd apns unregister --json"
)

type apnsRegisterOutput struct {
	SchemaVersion int    `json:"schemaVersion"`
	KeyID         string `json:"keyId"`
	Key           string `json:"key"`
}

func runAPNs(env Env, args []string) int {
	if len(args) == 0 {
		return fail(env, CodeBadRequest, "usage: "+usageAPNsRegister+"\n       "+usageAPNsActivate)
	}
	switch args[0] {
	case "register":
		return apnsRegister(env, args[1:])
	case "activate":
		return apnsActivate(env, args[1:])
	case "unregister":
		return apnsUnregister(env, args[1:])
	default:
		return fail(env, CodeBadRequest, fmt.Sprintf("unknown command \"apns %s\"", args[0]))
	}
}

// apnsRegister is called by the app over SSH and only stages the phone: notices keep using the active
// registration until the app has saved the key and calls activate (apns spec §4). The key goes back on
// stdout, so it never appears in a command line on the host.
func apnsRegister(env Env, args []string) int {
	parsed, err := parseArgs(args, []string{"--topic", "--environment"}, usageAPNsRegister)
	if err != nil {
		return failWith(env, err)
	}
	topic, hasTopic := parsed.Values["--topic"]
	environment, hasEnvironment := parsed.Values["--environment"]
	if len(parsed.Positional) != 1 || !hasTopic || !hasEnvironment {
		return fail(env, CodeBadRequest, "usage: "+usageAPNsRegister)
	}
	device, err := notify.NewDevice(parsed.Positional[0], topic, notify.Environment(environment), env.Now())
	if err != nil {
		return fail(env, CodeBadRequest, err.Error())
	}
	path := registrationPath(env)
	err = notify.WithRegistrationLock(path, func() error {
		registrations, err := notify.LoadRegistrations(path)
		if err != nil {
			// An unreadable file cannot send anything either; this registration is what repairs it.
			fmt.Fprintf(env.Stderr, "minis-hostd: replacing the unreadable registration: %v\n", err)
			registrations = notify.Registrations{}
		}
		return notify.SaveRegistrations(path, registrations.WithPending(device))
	})
	if err != nil {
		return fail(env, CodeStoreUnavailable, fmt.Sprintf("cannot save the registration: %v", err))
	}
	return emit(env, apnsRegisterOutput{
		SchemaVersion: SchemaVersion, KeyID: device.KeyID, Key: base64.StdEncoding.EncodeToString(device.Key),
	})
}

func apnsActivate(env Env, args []string) int {
	parsed, err := parseArgs(args, nil, usageAPNsActivate)
	if err != nil {
		return failWith(env, err)
	}
	if len(parsed.Positional) != 1 {
		return fail(env, CodeBadRequest, "usage: "+usageAPNsActivate)
	}
	path := registrationPath(env)
	var notPending error
	err = notify.WithRegistrationLock(path, func() error {
		registrations, err := notify.LoadRegistrations(path)
		if err != nil {
			return err
		}
		activated, err := registrations.Activated(parsed.Positional[0])
		if err != nil {
			notPending = err
			return nil
		}
		return notify.SaveRegistrations(path, activated)
	})
	if notPending != nil {
		return fail(env, CodeNotFound, notPending.Error())
	}
	if err != nil {
		return fail(env, CodeStoreUnavailable, fmt.Sprintf("cannot activate the registration: %v", err))
	}
	return emit(env, ackOutput{SchemaVersion: SchemaVersion, OK: true})
}

// apnsUnregister forgets the phone, for instance when the app removes the host: notices stop instead of
// arriving sealed with a key the phone no longer has.
func apnsUnregister(env Env, args []string) int {
	parsed, err := parseArgs(args, nil, usageAPNsUnregister)
	if err != nil {
		return failWith(env, err)
	}
	if len(parsed.Positional) != 0 {
		return fail(env, CodeBadRequest, "usage: "+usageAPNsUnregister)
	}
	path := registrationPath(env)
	err = notify.WithRegistrationLock(path, func() error {
		err := os.Remove(path)
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		return err
	})
	if err != nil {
		return fail(env, CodeStoreUnavailable, fmt.Sprintf("cannot remove the registration: %v", err))
	}
	return emit(env, ackOutput{SchemaVersion: SchemaVersion, OK: true})
}

func registrationPath(env Env) string {
	return filepath.Join(env.StateDir, notify.RegistrationFile)
}

// newNotifier builds the channel config.toml names; it reads the APNs key file, so a bad key fails
// here rather than on the first notice.
func newNotifier(env Env, cfg config.Config, client *http.Client) (notify.Notifier, error) {
	if cfg.APNs != nil {
		return notify.NewAPNs(*cfg.APNs, cfg.HostName, registrationPath(env), client)
	}
	return notify.NewBark(*cfg.Bark, client), nil
}
