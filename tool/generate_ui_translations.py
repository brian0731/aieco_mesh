import json
import re
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "lib" / "main.dart"
OUTPUT = ROOT / "lib" / "ui_translations.g.dart"
HAN = re.compile(r"[\u3400-\u9fff]")
LITERAL = re.compile(r"'(?:\\.|[^'\\])*'")
PLACEHOLDER = re.compile(r"\$\{[^}]+\}|\$[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*")


def dart_value(literal: str) -> str:
    value = literal[1:-1]
    return (value.replace(r"\'", "'").replace(r"\\", "\\")
            .replace(r"\n", "\n").replace(r"\r", "\r").replace(r"\t", "\t"))


def protect(value: str):
    placeholders = []
    def replace(match):
        placeholders.append(match.group(0))
        return f"ZXQPH{len(placeholders) - 1}QXZ"
    return PLACEHOLDER.sub(replace, value), placeholders


def restore(value: str, placeholders):
    for index, placeholder in enumerate(placeholders):
        value = re.sub(rf"ZXQPH\s*{index}\s*QXZ", placeholder, value,
                       flags=re.IGNORECASE)
    return value


def translate_one(item):
    source, target = item
    protected, placeholders = protect(source)
    query = urllib.parse.urlencode({"client": "gtx", "sl": "zh-TW",
                                    "tl": target, "dt": "t", "q": protected})
    url = "https://translate.googleapis.com/translate_a/single?" + query
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=25) as response:
                payload = json.loads(response.read().decode("utf-8"))
            translated = "".join(part[0] for part in payload[0] if part[0])
            return source, target, restore(translated, placeholders)
        except Exception:
            if attempt == 4:
                raise
            time.sleep(1.5 * (attempt + 1))


def dart_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False).replace("$", r"\$")


def pattern_entry(source: str, translated: str):
    matches = list(PLACEHOLDER.finditer(source))
    if not matches:
        return None
    parts, placeholders = [], []
    cursor = 0
    for match in matches:
        parts.extend((re.escape(source[cursor:match.start()]), "(.+?)"))
        placeholders.append(match.group(0))
        cursor = match.end()
    parts.append(re.escape(source[cursor:]))
    replacement = translated
    for index, placeholder in enumerate(placeholders, 1):
        replacement = replacement.replace(placeholder, f"@@{index}@@")
    return "^" + "".join(parts) + "$", replacement


def main():
    source_text = SOURCE.read_text(encoding="utf-8")
    strings = sorted({dart_value(match.group(0))
                      for match in LITERAL.finditer(source_text)
                      if HAN.search(match.group(0))})
    jobs = [(value, target) for value in strings for target in ("en", "zh-CN")]
    translations = {"en": {}, "zh-CN": {}}
    with ThreadPoolExecutor(max_workers=8) as executor:
        futures = [executor.submit(translate_one, job) for job in jobs]
        for count, future in enumerate(as_completed(futures), 1):
            source, target, translated = future.result()
            translations[target][source] = translated
            if count % 50 == 0:
                print(f"translated {count}/{len(jobs)}")

    lines = ["// GENERATED FILE. Run: python tool/generate_ui_translations.py",
             "// ignore_for_file: lines_longer_than_80_chars", "",
             "class UiTranslationPattern {",
             "  const UiTranslationPattern(this.pattern, this.replacement);",
             "  final RegExp pattern;", "  final String replacement;", "}", ""]
    for target, name in (("en", "uiEnglishTranslations"),
                         ("zh-CN", "uiSimplifiedTranslations")):
        lines.append(f"const Map<String, String> {name} = <String, String>{{")
        for key in strings:
            lines.append(f"  {dart_string(key)}: {dart_string(translations[target][key])},")
        lines.extend(["};", ""])
        patterns = [entry for key in strings
                    if (entry := pattern_entry(key, translations[target][key]))]
        pattern_name = ("uiEnglishPatterns" if target == "en"
                        else "uiSimplifiedPatterns")
        lines.append(f"final List<UiTranslationPattern> {pattern_name} = <UiTranslationPattern>[")
        for regex, replacement in patterns:
            lines.append(f"  UiTranslationPattern(RegExp({dart_string(regex)}), {dart_string(replacement)}),")
        lines.extend(["];", ""])
    OUTPUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUTPUT} with {len(strings)} source strings")


if __name__ == "__main__":
    main()
