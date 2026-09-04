package auth

import (
	"fmt"
	"strings"
	"testing"
	"time"
)

var testSecret = []byte("unit-test-secret")

func sample() User {
	return User{ID: "3f2504e0-4f89-11d3-9a0c-0305e82c3301", Phone: "13800000000",
		Nickname: "测试用户", Role: RoleAdmin}
}

func TestSignParseRoundTrip(t *testing.T) {
	want := sample()
	token, err := SignToken(testSecret, NewClaims(want, ScopeAdmin, time.Hour))
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	if n := len(strings.Split(token, ".")); n != 3 {
		t.Fatalf("token should have 3 segments, got %d", n)
	}
	got, err := ParseToken(testSecret, token)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got.UserID != want.ID || got.Phone != want.Phone || got.Role != want.Role {
		t.Fatalf("claims mismatch: %+v", got)
	}
	if got.Scope != ScopeAdmin {
		t.Fatalf("scope = %q, want %q", got.Scope, ScopeAdmin)
	}
}

func TestParseRejectsWrongSecret(t *testing.T) {
	token, _ := SignToken(testSecret, NewClaims(sample(), ScopeApp, time.Hour))
	if _, err := ParseToken([]byte("another-secret"), token); err != ErrTokenSignature {
		t.Fatalf("want ErrTokenSignature, got %v", err)
	}
}

// 改 payload 但不改签名段（把 role 换成 superadmin）必须被拒。
func TestParseRejectsTamperedPayload(t *testing.T) {
	token, _ := SignToken(testSecret, NewClaims(sample(), ScopeAdmin, time.Hour))
	parts := strings.Split(token, ".")
	forged, err := SignToken(testSecret, Claims{UserID: "x", Role: RoleSuperAdmin, ExpiresAt: time.Now().Add(time.Hour).Unix()})
	if err != nil {
		t.Fatalf("sign forged: %v", err)
	}
	parts[1] = strings.Split(forged, ".")[1]
	if _, err := ParseToken(testSecret, strings.Join(parts, ".")); err != ErrTokenSignature {
		t.Fatalf("want ErrTokenSignature, got %v", err)
	}
}

// alg=none 之类的头部替换同样过不了：签名恒按 HS256 校验。
func TestParseRejectsAlgNoneHeader(t *testing.T) {
	token, _ := SignToken(testSecret, NewClaims(sample(), ScopeApp, time.Hour))
	parts := strings.Split(token, ".")
	parts[0] = b64.EncodeToString([]byte(`{"alg":"none","typ":"JWT"}`))
	parts[2] = ""
	if _, err := ParseToken(testSecret, strings.Join(parts, ".")); err == nil {
		t.Fatal("alg=none token must be rejected")
	}
}

func TestParseRejectsExpired(t *testing.T) {
	token, _ := SignToken(testSecret, NewClaims(sample(), ScopeApp, -time.Second))
	if _, err := ParseToken(testSecret, token); err != ErrTokenExpired {
		t.Fatalf("want ErrTokenExpired, got %v", err)
	}
}

func TestParseRejectsMalformed(t *testing.T) {
	for _, bad := range []string{"", "abc", "a.b", "a.b.c.d"} {
		if _, err := ParseToken(testSecret, bad); err != ErrTokenMalformed {
			t.Fatalf("%q: want ErrTokenMalformed, got %v", bad, err)
		}
	}
}

func TestBearerToken(t *testing.T) {
	cases := map[string]string{
		"Bearer abc": "abc", "bearer abc": "abc", "BEARER  abc ": "abc",
		"abc": "abc", "": "", "   ": "",
	}
	for in, want := range cases {
		if got := BearerToken(in); got != want {
			t.Fatalf("BearerToken(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestPrintTokenForCrossLangCheck 打印一枚固定密钥的令牌，供 ai-svc/app/core/auth.py
// 与 admin-svc 的镜像实现做跨语言对拍（三处实现必须解得开同一枚令牌）。
//
//	go test ./internal/auth -run TestPrintTokenForCrossLangCheck -v
func TestPrintTokenForCrossLangCheck(t *testing.T) {
	token, err := SignToken([]byte(goldenSecret), goldenClaims())
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	fmt.Printf("CROSS_LANG_TOKEN=%s\n", token)
}

// goldenToken 被钉在 admin-svc/internal/auth/jwt_test.go 里做同样的断言。
// 只要这里签出来的字节和它不一致，就说明两边的令牌格式漂移了。
const (
	goldenSecret = "cross-lang-secret"
	goldenToken  = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." +
		"eyJzdWIiOiIxMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTUiLCJwaG9uZSI6IjEzOTAwMDAwMDAxIiwicm9sZSI6InVzZXIiLCJzY29wZSI6ImFwcCIsIm5pY2tuYW1lIjoi6Leo6K-t6KiAIiwiaWF0IjoxNzAwMDAwMDAwLCJleHAiOjQxMDI0NDQ4MDB9." +
		"Kdd_QYUODBu3dSb3KuNLjLy3hIRx6mTdUI6cUCMcEwE"
)

func goldenClaims() Claims {
	return Claims{
		UserID: "11111111-2222-3333-4444-555555555555",
		Phone:  "13900000001", Role: RoleUser, Scope: ScopeApp, Nickname: "跨语言",
		IssuedAt: 1700000000, ExpiresAt: 4102444800, // 2100-01-01，不会过期
	}
}

func TestGoldenTokenIsStable(t *testing.T) {
	got, err := SignToken([]byte(goldenSecret), goldenClaims())
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	if got != goldenToken {
		t.Fatalf("令牌格式已改变，admin-svc / ai-svc 的镜像实现需同步：\n got  %s\n want %s", got, goldenToken)
	}
}

func TestPasswordHashRoundTrip(t *testing.T) {
	hash, err := HashPassword("s3cret-pw")
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	if !CheckPassword(hash, "s3cret-pw") {
		t.Fatal("correct password rejected")
	}
	if CheckPassword(hash, "wrong-pw") {
		t.Fatal("wrong password accepted")
	}
	if CheckPassword("", "s3cret-pw") || CheckPassword(hash, "") {
		t.Fatal("empty inputs must not authenticate")
	}
}

func TestPasswordLengthBounds(t *testing.T) {
	if _, err := HashPassword("12345"); err != ErrBadPassword {
		t.Fatalf("short password: want ErrBadPassword, got %v", err)
	}
	// bcrypt 只吃前 72 字节，超长必须在入口挡掉而不是静默截断。
	if _, err := HashPassword(strings.Repeat("a", 65)); err != ErrBadPassword {
		t.Fatalf("long password: want ErrBadPassword, got %v", err)
	}
}

func TestNormalizePhone(t *testing.T) {
	ok := map[string]string{
		"13800000000": "13800000000", " 138 0000 0000 ": "13800000000",
		"138-0000-0000": "13800000000", "+8613800000000": "13800000000",
	}
	for in, want := range ok {
		got, err := NormalizePhone(in)
		if err != nil || got != want {
			t.Fatalf("NormalizePhone(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"", "12345", "12800000000", "1380000000a", "138000000000"} {
		if _, err := NormalizePhone(bad); err != ErrBadPhone {
			t.Fatalf("NormalizePhone(%q): want ErrBadPhone, got %v", bad, err)
		}
	}
}
