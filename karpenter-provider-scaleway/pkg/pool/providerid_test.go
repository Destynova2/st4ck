package pool

import "testing"

func TestFormatProviderID(t *testing.T) {
	got := FormatProviderID("fr-par-2", "11111111-2222-3333-4444-555555555555")
	want := "scaleway-em://fr-par-2/11111111-2222-3333-4444-555555555555"
	if got != want {
		t.Fatalf("FormatProviderID = %q, want %q", got, want)
	}
}

func TestParseProviderIDRoundTrip(t *testing.T) {
	zone, serverID, err := ParseProviderID(FormatProviderID("fr-par-2", "abc-123"))
	if err != nil {
		t.Fatalf("ParseProviderID returned error: %v", err)
	}
	if zone != "fr-par-2" || serverID != "abc-123" {
		t.Fatalf("ParseProviderID = (%q, %q), want (fr-par-2, abc-123)", zone, serverID)
	}
}

func TestParseProviderIDErrors(t *testing.T) {
	for _, providerID := range []string{
		"",
		"aws:///i-1234",
		"scaleway-em://",
		"scaleway-em://fr-par-2",
		"scaleway-em://fr-par-2/",
		"scaleway-em:///abc-123",
	} {
		if _, _, err := ParseProviderID(providerID); err == nil {
			t.Errorf("ParseProviderID(%q) should have failed", providerID)
		}
	}
}
