#!/usr/bin/env python3
"""Validate gettext PO files and generate yaourt's embedded Lua catalogues.

The PO files remain the translator-facing source of truth.  The generated Lua
module contains data only; external MO catalogues are parsed safely at runtime.
"""

from __future__ import annotations

import argparse
import ast
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


PLACEHOLDER_RE = re.compile(r"(?<!\{)\{([A-Za-z0-9_.-]+)\}")
FIELD_RE = re.compile(r"^(msgctxt|msgid|msgid_plural|msgstr)(?:\[(\d+)\])?\s+(.*)$")
SUSPICIOUS_TRANSLATION_RE = re.compile(
    r"ZXQ|QXZ|__VAR|_VAR\d|ЗXQ|КХЗ|СХКПХ|СХЗ|\ufffd|⁇"
)

# These names and command terms are part of yaourt's interface contract.
# Translators may move them within a sentence, but must not translate, truncate,
# or otherwise alter them.
PROTECTED_TERMS = (
    "yaourt",
    "pacman",
    "AUR",
    "PKGBUILD",
    "makepkg",
    "Babet",
    "git clone",
    "git",
)

HELP_DESCRIPTION_CONTEXTS = {
    "help.delegate",
    "help.install",
    "help.search",
    "help.update",
    "help.clean",
    "help.get_build_files",
    "help.show_help",
    "help.show_version",
}

HELP_REQUIRED_TOKENS = {
    "help.delegate": ("-Q", "-R", "-Sy"),
    "help.update": ("[M]",),
}

# CJK catalogues conventionally use full-width parentheses; they carry the
# same structure and are therefore accepted alongside their ASCII forms.
HELP_STRUCTURAL_MARKERS = {
    "(": ("(", "（"),
    ")": (")", "）"),
    "|": ("|",),
}


class CatalogError(RuntimeError):
    pass


@dataclass
class Entry:
    context: str | None = None
    msgid: str = ""
    msgid_plural: str | None = None
    msgstr: dict[int, str] = field(default_factory=dict)
    flags: set[str] = field(default_factory=set)
    references: list[str] = field(default_factory=list)


@dataclass
class Catalog:
    path: Path
    headers: dict[str, str]
    entries: list[Entry]

    @property
    def language(self) -> str:
        language = self.headers.get("Language", "").strip()
        if not language:
            raise CatalogError(f"{self.path}: missing Language header")
        return language

    @property
    def nplurals(self) -> int:
        value = self.headers.get("Plural-Forms", "")
        match = re.search(r"nplurals\s*=\s*(\d+)", value)
        if not match:
            raise CatalogError(f"{self.path}: invalid Plural-Forms header")
        result = int(match.group(1))
        if not 1 <= result <= 16:
            raise CatalogError(f"{self.path}: nplurals must be between 1 and 16")
        return result

    @property
    def plural(self) -> str:
        value = self.headers.get("Plural-Forms", "")
        match = re.search(r"plural\s*=\s*([^;]+)", value)
        if not match:
            raise CatalogError(f"{self.path}: invalid Plural-Forms expression")
        return match.group(1).strip()


def quoted(value: str, path: Path, line: int) -> str:
    try:
        parsed = ast.literal_eval(value)
    except (SyntaxError, ValueError) as exc:
        raise CatalogError(f"{path}:{line}: invalid PO string: {exc}") from exc
    if not isinstance(parsed, str):
        raise CatalogError(f"{path}:{line}: expected a quoted string")
    return parsed


def parse_po(path: Path) -> Catalog:
    entries: list[Entry] = []
    current = Entry()
    active: tuple[str, int | None] | None = None
    touched = False

    def finish() -> None:
        nonlocal current, active, touched
        if touched:
            entries.append(current)
        current = Entry()
        active = None
        touched = False

    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line:
            finish()
            continue
        if line.startswith("#,"):
            current.flags.update(part.strip() for part in line[2:].split(","))
            touched = True
            continue
        if line.startswith("#:"):
            current.references.extend(line[2:].strip().split())
            touched = True
            continue
        if line.startswith("#"):
            touched = True
            continue

        match = FIELD_RE.match(line)
        if match:
            name, plural_index, raw_value = match.groups()
            value = quoted(raw_value, path, line_number)
            index = int(plural_index) if plural_index is not None else None
            active = (name, index)
            touched = True
            if name == "msgctxt":
                current.context = value
            elif name == "msgid":
                current.msgid = value
            elif name == "msgid_plural":
                current.msgid_plural = value
            else:
                current.msgstr[index or 0] = value
            continue

        if line.startswith('"'):
            if active is None:
                raise CatalogError(f"{path}:{line_number}: orphan continuation")
            value = quoted(line, path, line_number)
            name, index = active
            if name == "msgctxt":
                current.context = (current.context or "") + value
            elif name == "msgid":
                current.msgid += value
            elif name == "msgid_plural":
                current.msgid_plural = (current.msgid_plural or "") + value
            else:
                current.msgstr[index or 0] = current.msgstr.get(index or 0, "") + value
            continue

        raise CatalogError(f"{path}:{line_number}: unsupported PO syntax: {raw}")

    finish()
    if not entries or entries[0].msgid != "":
        raise CatalogError(f"{path}: missing gettext header entry")

    header_text = entries[0].msgstr.get(0, "")
    headers: dict[str, str] = {}
    for line in header_text.splitlines():
        if ":" in line:
            name, value = line.split(":", 1)
            headers[name.strip()] = value.strip()
    return Catalog(path=path, headers=headers, entries=entries[1:])


def placeholders(value: str) -> set[str]:
    return set(PLACEHOLDER_RE.findall(value))


def entry_map(catalog: Catalog) -> dict[str, Entry]:
    result: dict[str, Entry] = {}
    for entry in catalog.entries:
        if not entry.context:
            raise CatalogError(f"{catalog.path}: every message needs msgctxt")
        if entry.context in result:
            raise CatalogError(f"{catalog.path}: duplicate context {entry.context!r}")
        if "fuzzy" in entry.flags:
            raise CatalogError(f"{catalog.path}: fuzzy entry {entry.context!r}")
        result[entry.context] = entry
    return result


def validate(base: Catalog, catalog: Catalog) -> None:
    base_entries = entry_map(base)
    entries = entry_map(catalog)
    missing = sorted(set(base_entries) - set(entries))
    extra = sorted(set(entries) - set(base_entries))
    if missing:
        raise CatalogError(f"{catalog.path}: missing contexts: {', '.join(missing)}")
    if extra:
        raise CatalogError(f"{catalog.path}: unknown contexts: {', '.join(extra)}")

    for context, source in base_entries.items():
        target = entries[context]
        if target.msgid != source.msgid or target.msgid_plural != source.msgid_plural:
            raise CatalogError(f"{catalog.path}: source text differs for {context!r}")
        expected_placeholders = placeholders(source.msgid)
        if source.msgid_plural:
            expected_placeholders |= placeholders(source.msgid_plural)
            expected_indexes = set(range(catalog.nplurals))
        else:
            expected_indexes = {0}
        if set(target.msgstr) != expected_indexes:
            raise CatalogError(
                f"{catalog.path}: {context!r} needs msgstr indexes "
                f"{sorted(expected_indexes)}, got {sorted(target.msgstr)}"
            )
        for index, translation in target.msgstr.items():
            if not translation:
                raise CatalogError(f"{catalog.path}: empty translation for {context!r}[{index}]")
            if SUSPICIOUS_TRANSLATION_RE.search(translation):
                raise CatalogError(
                    f"{catalog.path}: suspicious translation residue in "
                    f"{context!r}[{index}]"
                )
            if context.startswith("help.") and "\n" in translation:
                raise CatalogError(
                    f"{catalog.path}: help message {context!r} must stay on one line"
                )
            if context in HELP_DESCRIPTION_CONTEXTS and (
                "yaourt" in translation or "<" in translation or ">" in translation
            ):
                raise CatalogError(
                    f"{catalog.path}: command syntax leaked into help description "
                    f"{context!r}[{index}]"
                )
            if context in HELP_DESCRIPTION_CONTEXTS:
                for marker, accepted in HELP_STRUCTURAL_MARKERS.items():
                    if marker in source.msgid and not any(
                        candidate in translation for candidate in accepted
                    ):
                        raise CatalogError(
                            f"{catalog.path}: structural marker {marker!r} is missing "
                            f"from {context!r}[{index}]"
                        )
                for token in HELP_REQUIRED_TOKENS.get(context, ()):
                    if token not in translation:
                        raise CatalogError(
                            f"{catalog.path}: interface token {token!r} is missing "
                            f"from {context!r}[{index}]"
                        )
            actual = placeholders(translation)
            if actual != expected_placeholders:
                raise CatalogError(
                    f"{catalog.path}: placeholders for {context!r}[{index}] are "
                    f"{sorted(actual)}, expected {sorted(expected_placeholders)}"
                )
            source_variant = source.msgid
            if index > 0 and source.msgid_plural:
                source_variant = source.msgid_plural
            for term in PROTECTED_TERMS:
                required = source_variant.count(term)
                if required and translation.count(term) < required:
                    raise CatalogError(
                        f"{catalog.path}: protected term {term!r} was altered "
                        f"in {context!r}[{index}]"
                    )


def lua_string(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
        .replace("\0", "\\000")
    )
    return f'"{escaped}"'


def header_list(catalog: Catalog, name: str) -> str:
    return catalog.headers.get(name, "").strip()


def generate_lua(catalogs: list[Catalog]) -> str:
    aliases: dict[str, str] = {}
    lines = [
        "-- Generated by tools/compile_catalogs.py; do not edit by hand.",
        "-- Source of truth: po/*.po",
        "return {",
        "    aliases = {",
    ]
    for catalog in catalogs:
        for alias in filter(None, (item.strip() for item in header_list(catalog, "X-Yaourt-Aliases").split(","))):
            if alias in aliases and aliases[alias] != catalog.language:
                raise CatalogError(f"locale alias {alias!r} is declared more than once")
            aliases[alias] = catalog.language
    for alias in sorted(aliases):
        lines.append(f"        [{lua_string(alias)}] = {lua_string(aliases[alias])},")
    lines.extend(["    },", "    catalogs = {"])

    for catalog in sorted(catalogs, key=lambda item: item.language):
        lines.append(f"        [{lua_string(catalog.language)}] = {{")
        lines.append(f"            language = {lua_string(catalog.language)},")
        lines.append(f"            name = {lua_string(catalog.headers.get('Language-Team', catalog.language))},")
        lines.append(f"            nplurals = {catalog.nplurals},")
        lines.append(f"            plural = {lua_string(catalog.plural)},")
        lines.append("            answers = {")
        for kind, header in (("yes", "X-Yaourt-Yes"), ("no", "X-Yaourt-No"), ("manual", "X-Yaourt-Manual")):
            lines.append(f"                {kind} = {lua_string(header_list(catalog, header))},")
        lines.append("            },")
        lines.append("            messages = {")
        for context, entry in sorted(entry_map(catalog).items()):
            values = [entry.msgstr[index] for index in sorted(entry.msgstr)]
            if len(values) == 1:
                rendered = lua_string(values[0])
            else:
                rendered = "{ " + ", ".join(lua_string(value) for value in values) + " }"
            lines.append(f"                [{lua_string(context)}] = {rendered},")
        lines.extend(["            },", "        },"])
    lines.extend(["    },", "}", ""])
    return "\n".join(lines)


def pot_string(value: str) -> list[str]:
    # Always use a multiline representation for strings containing newlines.
    if "\n" not in value:
        return [lua_string(value)]
    parts = value.splitlines(keepends=True)
    result = ['""']
    for part in parts:
        result.append(lua_string(part))
    if parts and not parts[-1].endswith("\n"):
        pass
    return result


def generate_pot(base: Catalog) -> str:
    lines = [
        '# Translation template for yaourt.',
        'msgid ""',
        'msgstr ""',
        '"Project-Id-Version: yaourt 0.7.0\\n"',
        '"Content-Type: text/plain; charset=UTF-8\\n"',
        '"Content-Transfer-Encoding: 8bit\\n"',
        '"Plural-Forms: nplurals=2; plural=(n != 1);\\n"',
        "",
    ]
    for entry in base.entries:
        if entry.references:
            lines.append("#: " + " ".join(entry.references))
        lines.append("msgctxt " + lua_string(entry.context or ""))
        msgid_lines = pot_string(entry.msgid)
        lines.append("msgid " + msgid_lines[0])
        lines.extend(msgid_lines[1:])
        if entry.msgid_plural is not None:
            plural_lines = pot_string(entry.msgid_plural)
            lines.append("msgid_plural " + plural_lines[0])
            lines.extend(plural_lines[1:])
            lines.extend(['msgstr[0] ""', 'msgstr[1] ""'])
        else:
            lines.append('msgstr ""')
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--po-dir", type=Path, default=Path("po"))
    parser.add_argument("--output", type=Path, default=Path("lib/i18n_catalogs.lua"))
    parser.add_argument("--pot", type=Path, default=Path("po/yaourt.pot"))
    parser.add_argument("--check", action="store_true", help="validate without writing generated files")
    args = parser.parse_args()

    try:
        paths = sorted(path for path in args.po_dir.glob("*.po") if path.name != "yaourt.pot")
        if not paths:
            raise CatalogError(f"{args.po_dir}: no PO files found")
        catalogs = [parse_po(path) for path in paths]
        by_language = {catalog.language: catalog for catalog in catalogs}
        if len(by_language) != len(catalogs):
            raise CatalogError("duplicate Language header")
        base = by_language.get("en")
        if not base:
            raise CatalogError("po/en.po is required as the source catalogue")
        for catalog in catalogs:
            validate(base, catalog)
        generated = generate_lua(catalogs)
        if not args.check:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(generated, encoding="utf-8")
            args.pot.write_text(generate_pot(base), encoding="utf-8")
        print(f"[PASS] {len(catalogs)} catalogue(s), {len(base.entries)} message(s)")
        return 0
    except (CatalogError, OSError) as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
