package storage

import (
	"strconv"
	"strings"
)

// ParseByteRange supports "bytes=start-end" / "bytes=start-" / "bytes=-N".
// ok=false means Range is present but unsatisfiable. Shared by video & upload playback.
func ParseByteRange(header string, size int64) (start, end int64, partial bool, ok bool) {
	if size <= 0 {
		return 0, -1, false, true
	}
	header = strings.TrimSpace(header)
	if header == "" {
		return 0, size - 1, false, true
	}
	if !strings.HasPrefix(header, "bytes=") {
		return 0, size - 1, false, true
	}
	spec := strings.TrimPrefix(header, "bytes=")
	if i := strings.IndexByte(spec, ','); i >= 0 {
		spec = spec[:i]
	}
	parts := strings.SplitN(spec, "-", 2)
	if len(parts) != 2 {
		return 0, 0, false, false
	}

	if parts[0] == "" {
		// suffix form: bytes=-N
		n, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil || n <= 0 {
			return 0, 0, false, false
		}
		if n > size {
			n = size
		}
		return size - n, size - 1, true, true
	}

	s, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || s < 0 {
		return 0, 0, false, false
	}
	if s >= size {
		return 0, 0, false, false
	}
	if parts[1] == "" {
		return s, size - 1, true, true
	}
	e, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || e < s {
		return 0, 0, false, false
	}
	if e >= size {
		e = size - 1
	}
	return s, e, true, true
}
