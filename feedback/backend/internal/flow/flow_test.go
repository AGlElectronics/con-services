package flow

import "testing"

func TestParsePolarity(t *testing.T) {
	cases := map[string]string{
		"1": "positive", "Positive": "positive", "2": "negative", "Negative": "negative",
	}
	for in, want := range cases {
		got, ok := parsePolarity(in)
		if !ok || got != want {
			t.Fatalf("%q → %q/%v want %q", in, got, ok, want)
		}
	}
}

func TestParseAnonymousButtons(t *testing.T) {
	neg := "negative"
	pos := "positive"
	if anon, ok := parseAnonymous(btnAnonymous, &neg); !ok || !anon {
		t.Fatalf("Anonymous button")
	}
	if anon, ok := parseAnonymous(btnNamed, &neg); !ok || anon {
		t.Fatalf("Named button")
	}
	if anon, ok := parseAnonymous(btnUseDefault, &neg); !ok || !anon {
		t.Fatalf("default negative → anonymous")
	}
	if anon, ok := parseAnonymous(btnUseDefault, &pos); !ok || anon {
		t.Fatalf("default positive → named")
	}
}

func TestParseBoardNotifyButtons(t *testing.T) {
	if n, ok := parseBoardNotify(btnNotifyBoard); !ok || !n {
		t.Fatal("notify")
	}
	if n, ok := parseBoardNotify(btnSkipBoard); !ok || n {
		t.Fatal("skip")
	}
	if n, ok := parseBoardNotify(btnUseDefault); !ok || !n {
		t.Fatal("default notify")
	}
}

func TestParseDepartment(t *testing.T) {
	e := &Engine{cfg: Config{Departments: []string{"Board", "Ops", "HR"}}}
	if d, ok := e.parseDepartment("Ops"); !ok || d != "Ops" {
		t.Fatalf("got %q %v", d, ok)
	}
}

func TestAnonymousDefault(t *testing.T) {
	if !ApplyAnonymousDefault("negative") || ApplyAnonymousDefault("positive") {
		t.Fatal("defaults wrong")
	}
}
