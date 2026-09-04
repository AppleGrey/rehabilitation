package auth

import (
	"strings"
	"testing"
)

// goldenToken 由 core-svc 用密钥 "cross-lang-secret" 签发（见
// core-svc/internal/auth/jwt_test.go 的 TestPrintTokenForCrossLangCheck）。
// 三处实现——core-svc 签发、admin-svc 校验、ai-svc/app/core/auth.py 解析——
// 必须都能解开同一枚令牌。把它钉成常量：任何一侧的格式漂移都会让对应的测试炸掉。
const (
	goldenSecret = "cross-lang-secret"
	goldenToken  = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." +
		"eyJzdWIiOiIxMTExMTExMS0yMjIyLTMzMzMtNDQ0NC01NTU1NTU1NTU1NTUiLCJwaG9uZSI6IjEzOTAwMDAwMDAxIiwicm9sZSI6InVzZXIiLCJzY29wZSI6ImFwcCIsIm5pY2tuYW1lIjoi6Leo6K-t6KiAIiwiaWF0IjoxNzAwMDAwMDAwLCJleHAiOjQxMDI0NDQ4MDB9." +
		"Kdd_QYUODBu3dSb3KuNLjLy3hIRx6mTdUI6cUCMcEwE"
)

func TestParsesGoldenTokenFromCoreSvc(t *testing.T) {
	c, err := ParseToken([]byte(goldenSecret), goldenToken)
	if err != nil {
		t.Fatalf("admin-svc 解不开 core-svc 签发的令牌: %v", err)
	}
	if c.UserID != "11111111-2222-3333-4444-555555555555" {
		t.Fatalf("sub = %q", c.UserID)
	}
	if c.Phone != "13900000001" || c.Role != "user" || c.Scope != "app" {
		t.Fatalf("claims mismatch: %+v", c)
	}
	if c.Nickname != "跨语言" {
		t.Fatalf("nickname = %q（UTF-8 未正确往返）", c.Nickname)
	}
}

func TestGoldenTokenRejectedWithWrongSecret(t *testing.T) {
	if _, err := ParseToken([]byte("nope"), goldenToken); err != ErrTokenSignature {
		t.Fatalf("want ErrTokenSignature, got %v", err)
	}
}

func TestParseRejectsTamperedSignature(t *testing.T) {
	tampered := goldenToken[:len(goldenToken)-4] + "AAAA"
	if _, err := ParseToken([]byte(goldenSecret), tampered); err != ErrTokenSignature {
		t.Fatalf("want ErrTokenSignature, got %v", err)
	}
}

// 提权尝试：把 payload 换成 role=superadmin 但保留原签名段，必须被拒。
func TestParseRejectsRoleEscalation(t *testing.T) {
	parts := strings.Split(goldenToken, ".")
	parts[1] = b64.EncodeToString(
		[]byte(`{"sub":"x","role":"superadmin","scope":"admin","exp":4102444800}`))
	if _, err := ParseToken([]byte(goldenSecret), strings.Join(parts, ".")); err != ErrTokenSignature {
		t.Fatalf("提权令牌必须被拒，got %v", err)
	}
}

func TestParseRejectsMalformed(t *testing.T) {
	for _, bad := range []string{"", "abc", "a.b", "a.b.c.d"} {
		if _, err := ParseToken([]byte(goldenSecret), bad); err != ErrTokenMalformed {
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

func TestIsAdminRole(t *testing.T) {
	if !IsAdminRole(RoleAdmin) || !IsAdminRole(RoleSuperAdmin) {
		t.Fatal("admin/superadmin 应通过")
	}
	for _, r := range []string{"user", "", "Admin", "superuser"} {
		if IsAdminRole(r) {
			t.Fatalf("role %q 不应被当作管理员", r)
		}
	}
}
