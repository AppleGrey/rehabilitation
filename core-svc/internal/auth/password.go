package auth

import (
	"errors"
	"regexp"
	"strings"
	"unicode/utf8"

	"golang.org/x/crypto/bcrypt"
)

// bcrypt 只处理前 72 字节，更长的密码在新版本里会直接报错，因此在入口就限长。
const (
	minPasswordLen = 6
	maxPasswordLen = 64
)

var phoneRe = regexp.MustCompile(`^1[3-9]\d{9}$`)

var (
	ErrBadPhone    = errors.New("手机号格式不正确（需 11 位大陆手机号）")
	ErrBadPassword = errors.New("密码长度需为 6-64 位")
)

func HashPassword(plain string) (string, error) {
	if err := ValidatePassword(plain); err != nil {
		return "", err
	}
	b, err := bcrypt.GenerateFromPassword([]byte(plain), bcrypt.DefaultCost)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func CheckPassword(hash, plain string) bool {
	if hash == "" || plain == "" {
		return false
	}
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(plain)) == nil
}

func ValidatePassword(plain string) error {
	n := utf8.RuneCountInString(plain)
	if n < minPasswordLen || n > maxPasswordLen || len(plain) > 72 {
		return ErrBadPassword
	}
	return nil
}

// NormalizePhone 去掉空格与常见分隔符后校验。暂不支持国际号码。
func NormalizePhone(raw string) (string, error) {
	p := strings.NewReplacer(" ", "", "-", "", "+86", "").Replace(strings.TrimSpace(raw))
	if !phoneRe.MatchString(p) {
		return "", ErrBadPhone
	}
	return p, nil
}
