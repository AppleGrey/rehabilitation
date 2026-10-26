from pathlib import Path

p = Path(r"D:\codes\rehabilitation\frontend\pubspec.lock")
text = p.read_text(encoding="utf-8")
start = text.find("<<<<<<< HEAD")
end = text.find(">>>>>>> main")
if start < 0 or end < 0:
    raise SystemExit("markers missing")
end = text.find("\n", end)
replacement = """  google_mlkit_commons:
    dependency: transitive
    description:
      name: google_mlkit_commons
      sha256: "3e69fea4211727732cc385104e675ad1e40b29f12edd492ee52fa108423a6124"
      url: "https://pub.dev"
    source: hosted
    version: "0.11.1"
  google_mlkit_pose_detection:
    dependency: "direct main"
    description:
      name: google_mlkit_pose_detection
      sha256: "9157847e41fff1703b6b16b1af5508cf5def85cad96b7b724394fa9fe386cb8f"
      url: "https://pub.dev"
    source: hosted
    version: "0.14.1"
  hooks:
    dependency: transitive
    description:
      name: hooks
      sha256: "9a62a50b50b769a737bc0e844ac38759fc78f76836d37edad06fa21e182055ba"
      url: "https://pub.dev"
    source: hosted
    version: "2.0.2"
"""
text = text[:start] + replacement + text[end + 1 :]
if "<<<<<<<" in text or ">>>>>>>" in text:
    raise SystemExit("markers remain")
p.write_text(text, encoding="utf-8", newline="\n")
print("lock fixed")
