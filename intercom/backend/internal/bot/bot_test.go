package bot

import "testing"

func TestSplitCommand(t *testing.T) {
	cases := []struct {
		in      string
		wantCmd string
		wantArg string
	}{
		{"/board Do we have radios?", "/board", "Do we have radios?"},
		{"/board@Confuratio_staff_bot radios?", "/board", "radios?"},
		{"/idea water stations", "/idea", "water stations"},
		{"/HELP", "/help", ""},
		{"/start", "/start", ""},
	}
	for _, tc := range cases {
		cmd, arg := splitCommand(tc.in)
		if cmd != tc.wantCmd || arg != tc.wantArg {
			t.Fatalf("%q → (%q,%q), want (%q,%q)", tc.in, cmd, arg, tc.wantCmd, tc.wantArg)
		}
	}
}
