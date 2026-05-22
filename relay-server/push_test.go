package main

import "testing"

func TestParseAPNSEnvironment(t *testing.T) {
	tests := []struct {
		name     string
		raw      string
		fallback APNSEnvironment
		want     APNSEnvironment
		wantErr  bool
	}{
		{
			name:     "empty uses fallback",
			raw:      "",
			fallback: apnsEnvironmentProduction,
			want:     apnsEnvironmentProduction,
		},
		{
			name:     "sandbox",
			raw:      "sandbox",
			fallback: apnsEnvironmentProduction,
			want:     apnsEnvironmentSandbox,
		},
		{
			name:     "development alias",
			raw:      "development",
			fallback: apnsEnvironmentProduction,
			want:     apnsEnvironmentSandbox,
		},
		{
			name:     "production",
			raw:      "production",
			fallback: apnsEnvironmentSandbox,
			want:     apnsEnvironmentProduction,
		},
		{
			name:     "release alias",
			raw:      "release",
			fallback: apnsEnvironmentSandbox,
			want:     apnsEnvironmentProduction,
		},
		{
			name:     "unknown",
			raw:      "staging",
			fallback: apnsEnvironmentSandbox,
			wantErr:  true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseAPNSEnvironment(tt.raw, tt.fallback)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Fatalf("parseAPNSEnvironment(%q) = %q, want %q", tt.raw, got, tt.want)
			}
		})
	}
}
