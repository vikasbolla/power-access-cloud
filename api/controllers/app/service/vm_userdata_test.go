package service

import (
	"encoding/base64"
	"os"
	"strings"
	"testing"
)

// testLogger satisfies the templateLogger interface using t.Logf / t.Errorf.
type testLogger struct{ t *testing.T }

func (l *testLogger) Error(err error, msg string, _ ...interface{}) {
	l.t.Errorf("%s: %v", msg, err)
}

// TestGenerateK8SUserData renders the k3s cloud-init template with a real or
// placeholder SSH key and writes the decoded YAML to /tmp/k8s-userdata.yaml so
// you can paste it verbatim into the IBM PowerVS "User data" field when creating
// a VM manually — without going through PAC at all.
//
// Usage — run with your actual public key:
//
//	SSH_PUB_KEY="ssh-rsa AAAA..." go test ./controllers/app/service/ -run TestGenerateK8SUserData -v
//
// If SSH_PUB_KEY is not set, a placeholder key is used so the output is still
// valid YAML that can be inspected.
func TestGenerateK8SUserData(t *testing.T) {
	key := os.Getenv("SSH_PUB_KEY")
	if key == "" {
		key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCjdrvM0OeuAFNSaMD73I4cMBdPkwiAD1YybZBayuxlVEFFLNp2toRx0xq1nNeZmKR4G7mVtJq6mNwM2/vcuw5WNMZScb3X7FtERdEc1lm5/M/zCQ4XReIm9toQa9PNDfXHRzdxkOIRlnqD03g80B5S/WlmJveS5cgKlFw2AJM9bD6/9jk9h3BBh7m73AspSQq7rucKFHvcOPsjG/K9qaLkrBL3lxmfcshlFIwLwZxzCFsGsXrq4A6vSf5aJ1boWEerpUzP6dDgJZctGgxAuRyXHlzCZQPhZRHjujTsSMY9tK8eGlg3Dni2b2EayIgSnua7+iK0P1LlYqHJHXAPYfHdguaDg52jR3SUK7EsDA0T7kCUZKB1CIzi9lM4QlGmctl1wis0IYbDTzwyFzj3o/Xw2Yq6u/cs3ashuE0OG7G7DN8H3yZV0+z/6UiMh9J8bprB/1eQQkWzGqfFzrOcGOvGR44sYb6mSkN5VuBMCrlCOaoleJU+tl21Ww9QWm28O45OR0+ZDk+d+gs8dq01gxynZxGbVdbFuPkP/JDe/gybg/BVqjuAI4NdwYziU6q8X3GMjickJB+WGtc5ud5Q4r/lTmk59Oe2deLD/ZL+39QeNPrgVdqP2M+lFO0m59bC5w65rWdk7923BHzUlHdZOKL5ORDzAh15qfyQ20wBYmcRCQ== vikas.satyanarayana.bolla@ibm.com"
		t.Log("SSH_PUB_KEY not set — using placeholder key. " +
			"Re-run with SSH_PUB_KEY=\"$(cat ~/.ssh/id_rsa.pub)\" for a real key.")
	}

	encoded := renderK8SUserData(t, []string{key})

	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatalf("base64 decode failed: %v", err)
	}

	// Write next to this test file so it is easy to find in the repo.
	if err := os.MkdirAll("testdata", 0755); err != nil {
		t.Fatalf("failed to create testdata dir: %v", err)
	}
	outPath := "testdata/k8s-userdata.yaml"
	if err := os.WriteFile(outPath, decoded, 0600); err != nil {
		t.Fatalf("failed to write output file: %v", err)
	}

	t.Logf("\n\nCloud-init written to api/controllers/app/service/%s\nPaste its contents into the IBM PowerVS 'User data' field.\n\n%s", outPath, string(decoded))
}

// TestGenerateK8SUserDataMultipleKeys verifies that multiple SSH keys are all
// injected into the authorized_keys line inside the cloud-init script.
func TestGenerateK8SUserDataMultipleKeys(t *testing.T) {
	keys := []string{
		"ssh-rsa AAAAB3NzaC1yc2E key-one@example.com",
		"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5 key-two@example.com",
	}

	encoded := renderK8SUserData(t, keys)

	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatalf("base64 decode failed: %v", err)
	}

	content := string(decoded)
	for _, key := range keys {
		if !strings.Contains(content, key) {
			t.Errorf("expected SSH key %q to appear in rendered cloud-init", key)
		}
	}

	t.Logf("Rendered cloud-init with %d keys:\n%s", len(keys), content)
}

// renderK8SUserData calls getK8SUserDataWithLogger with a test-friendly logger
// and returns the base64-encoded cloud-init string.
func renderK8SUserData(t *testing.T, sshKeys []string) string {
	t.Helper()
	encoded := getK8SUserDataWithLogger(sshKeys, &testLogger{t: t})
	if encoded == "" {
		t.Fatal("getK8SUserDataWithLogger returned empty string — check template parsing")
	}
	return encoded
}
