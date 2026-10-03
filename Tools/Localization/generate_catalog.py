#!/usr/bin/env python3
"""Builds the String Catalogs from the translation sources in this folder and validates them.

Checks (the build fails on any problem):
  * every key has all five languages (en, es, ru, de, fr), none empty;
  * format placeholders match across languages;
  * every key used in Swift via L10n.tr("…") exists;
  * every dynamic key family (errors, keys, capabilities, help articles, …) is complete.

Usage: python3 Tools/Localization/generate_catalog.py [--check]
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(pathlib.Path(__file__).parent))

import strings_cast  # noqa: E402
import strings_core  # noqa: E402
import strings_errors  # noqa: E402
import strings_purchase  # noqa: E402
import strings_redesign  # noqa: E402
import strings_support  # noqa: E402
import strings_v2  # noqa: E402

LANGS = ["en", "es", "ru", "de", "fr"]
MODULES = [strings_errors, strings_core, strings_cast, strings_purchase, strings_support, strings_redesign, strings_v2]
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?(lld|ld|d|@|%)")

INFO_PLIST = {
    "NSLocalNetworkUsageDescription": (
        "Finds TVs on your Wi‑Fi network and sends remote commands, photos and your screen to the TV you choose.",
        "Busca TV en tu red Wi‑Fi y envía órdenes, fotos y tu pantalla a la TV que elijas.",
        "Находит телевизоры в вашей сети Wi‑Fi и передаёт команды, фото и изображение экрана на выбранный телевизор.",
        "Findet Fernseher in deinem WLAN und sendet Befehle, Fotos und deinen Bildschirm an den gewählten Fernseher.",
        "Trouve les téléviseurs sur votre réseau Wi‑Fi et envoie commandes, photos et votre écran au téléviseur choisi.",
    ),
    "CFBundleDisplayName": ("TV Remote", "TV Remote", "TV Remote", "TV Remote", "TV Remote"),
}

# Dynamic key families built from Swift enums (keep in sync with the enums; unit tests cross-check).
ERROR_CODES = (
    [f"net-00{i}" for i in range(1, 6)] + [f"pair-00{i}" for i in range(1, 7)] + [f"ses-00{i}" for i in range(1, 4)]
    + [f"txt-00{i}" for i in range(1, 4)] + [f"app-00{i}" for i in range(1, 4)] + [f"med-00{i}" for i in range(1, 7)]
    + [f"mir-00{i}" for i in range(1, 8)] + [f"iap-00{i}" for i in range(1, 7)] + [f"ofr-00{i}" for i in range(1, 6)]
    + ["sup-001", "sup-002", "gen-001"]
)
RECOVERY = ["retry", "openSettings", "pairAgain", "searchAgain", "useButtons", "openHome", "chooseAnotherFile",
            "showSetupSteps", "restorePurchases", "managePayment", "contactSupport", "turnOnWithRemote"]
CAPABILITIES = ["remoteControl", "textInput", "appLaunch", "photos", "video", "screenMirroring", "powerOff", "wakeOnNetwork"]
CAP_NOTES = ["holdNotSupported", "textNeedsFocusedField", "textReplaceOnly", "appListIsCatalog", "appLaunchUnconfirmed",
             "noMediaRenderer", "mediaRendererUnreachable", "videoFormatLimited", "mirroringNeedsBrowser",
             "mirroringNoBrowserOnPlatform", "mirroringVideoOnlyNoAudio", "airPlayAvailable",
             "wakeNeedsMulticastEntitlement", "wakeNeedsMacAddress", "wakeNeedsTVSetting", "notCheckedYet", "protocolUnsupported"]
COMMANDS = ["up", "down", "left", "right", "ok", "back", "home", "menu", "settings", "info", "guide", "input", "volumeUp",
            "volumeDown", "mute", "channelUp", "channelDown", "playPause", "play", "pause", "stop", "rewind", "fastForward",
            "next", "previous", "powerOff", "powerToggle"] + [f"digit{i}" for i in range(10)]
SUPPORT_CATEGORIES = ["tvNotFound", "cannotConnect", "buttonsNotWorking", "textNotWorking", "appsNotLaunching",
                      "mediaNotShowing", "mirroringProblem", "paidNoAccess", "trialOffers", "changePlan", "refund", "privacy", "other"]
HELP_ARTICLES = {"tvNotFound": 5, "cannotConnect": 4, "buttonsNotWorking": 4, "textNotWorking": 4, "appsNotLaunching": 4,
                 "mediaNotShowing": 4, "mirroringProblem": 4, "paidNoAccess": 4, "trialOffers": 4, "changePlan": 4,
                 "refund": 3, "privacy": 4}
PLANS = ["monthly", "yearly", "lifetime"]


def dynamic_keys():
    keys = set()
    for code in ERROR_CODES:
        keys |= {f"error.{code}.title", f"error.{code}.message"}
    keys |= {f"action.{a}" for a in RECOVERY}
    keys |= {f"capability.{c}" for c in CAPABILITIES}
    keys |= {f"capability.note.{n}" for n in CAP_NOTES}
    keys |= {f"capability.status.{s}" for s in ["unknown", "supported", "limited", "unsupported"]}
    keys |= {f"key.{c}" for c in COMMANDS}
    keys |= {f"paywall.{c}.{p}" for c in ["remote", "mirroring"] for p in ["title", "subtitle"]}
    keys |= {f"paywall.reason.{f}" for f in ["remote", "photo", "mirroring"]}
    keys |= {f"plan.{p}" for p in PLANS}
    keys |= {f"purchase.success.{p}" for p in PLANS}
    keys |= {f"pro.inactive.{r}" for r in ["neverPurchased", "expired", "billingRetry", "revoked"]}
    keys |= {f"support.category.{c}" for c in SUPPORT_CATEGORIES}
    keys |= {f"bonus.freeWeek.then.{p}" for p in ["monthly", "yearly"]}
    keys |= {f"onboarding.page{i}.{part}" for i in range(1, 4) for part in ["title", "subtitle"]}
    keys |= {f"banner.pro.plan.{p}" for p in PLANS}
    keys |= {f"pro.planName.{p}" for p in PLANS}
    keys |= {f"help.topic.{t}{suffix}" for t in ["connect", "remote", "media", "purchases", "privacy"] for suffix in ["", ".detail"]}
    for article, steps in HELP_ARTICLES.items():
        keys |= {f"help.{article}.title", f"help.{article}.intro"} | {f"help.{article}.step{i}" for i in range(1, steps + 1)}
    return keys


def swift_keys():
    keys = set()
    call = re.compile(r"L10n\.tr\((.*?)\)(?:\s|$|[,.\]}])", re.S)
    literal = re.compile(r'"((?:[^"\\]|\\.)*)"')
    for path in (ROOT / "TVRemoteScreenMirroring").rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        for match in re.finditer(r"L10n\.tr\(", text):
            # Collect the argument text up to the matching closing parenthesis.
            depth, i = 1, match.end()
            while i < len(text) and depth:
                depth += {"(": 1, ")": -1}.get(text[i], 0)
                i += 1
            args = text[match.end():i - 1]
            for lit in literal.findall(args):
                if "\\(" in lit or not re.fullmatch(r"[a-z][A-Za-z0-9]*(\.[A-Za-z0-9-]+)+", lit):
                    continue
                keys.add(lit)
        keys |= set(re.findall(r'"(paywall\.benefit\.[A-Za-z]+)"', text))
    _ = call
    return keys


def placeholders(value):
    found = []
    auto = 0
    for index, kind in PLACEHOLDER.findall(value):
        if kind == "%":
            continue
        kind = "lld" if kind in ("lld", "ld", "d") else kind
        if index:
            found.append((int(index), kind))
        else:
            auto += 1
            found.append((auto, kind))
    return sorted(found)


def collect():
    strings, plurals = {}, {}
    problems = []
    for module in MODULES:
        for key, values in module.STRINGS.items():
            if key in strings or key in plurals:
                problems.append(f"duplicate key {key}")
            strings[key] = values
        for key, forms in module.PLURALS.items():
            if key in strings or key in plurals:
                problems.append(f"duplicate key {key}")
            plurals[key] = forms
    for key, values in strings.items():
        if len(values) != 5 or any(not v for v in values):
            problems.append(f"{key}: needs 5 non-empty translations")
            continue
        base = placeholders(values[0])
        for lang, value in zip(LANGS, values):
            if placeholders(value) != base:
                problems.append(f"{key} [{lang}]: placeholders {placeholders(value)} != en {base}")
    for key, forms in plurals.items():
        for lang in LANGS:
            if lang not in forms or "other" not in forms[lang]:
                problems.append(f"{key} [{lang}]: missing plural 'other'")
                continue
            base = placeholders(forms["en"]["other"])
            for category, value in forms[lang].items():
                if placeholders(value) != base:
                    problems.append(f"{key} [{lang}.{category}]: placeholder mismatch")
    return strings, plurals, problems


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def build_catalog(strings, plurals):
    catalog = {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    for key in sorted(strings):
        catalog["strings"][key] = {
            "extractionState": "manual",
            "localizations": {lang: unit(value) for lang, value in zip(LANGS, strings[key])},
        }
    for key in sorted(plurals):
        catalog["strings"][key] = {
            "extractionState": "manual",
            "localizations": {
                lang: {"variations": {"plural": {cat: unit(v) for cat, v in sorted(plurals[key][lang].items())}}}
                for lang in LANGS
            },
        }
    catalog["strings"] = dict(sorted(catalog["strings"].items()))
    return catalog


def main():
    check_only = "--check" in sys.argv
    strings, plurals, problems = collect()
    known = set(strings) | set(plurals)
    for key in sorted(swift_keys() - known):
        problems.append(f"missing key used in Swift: {key}")
    for key in sorted(dynamic_keys() - known):
        problems.append(f"missing dynamic key: {key}")
    if problems:
        print("\n".join(problems))
        print(f"\n{len(problems)} localization problem(s).")
        sys.exit(1)

    catalog = build_catalog(strings, plurals)
    info = {"sourceLanguage": "en", "strings": {}, "version": "1.0"}
    for key, values in INFO_PLIST.items():
        info["strings"][key] = {"extractionState": "manual", "localizations": {l: unit(v) for l, v in zip(LANGS, values)}}

    outputs = {
        ROOT / "TVRemoteScreenMirroring/Resources/Localization/Localizable.xcstrings": catalog,
        ROOT / "TVRemoteScreenMirroring/Resources/Localization/InfoPlist.xcstrings": info,
    }
    for path, content in outputs.items():
        text = json.dumps(content, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
        if check_only:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                print(f"{path.relative_to(ROOT)} is out of date; run generate_catalog.py")
                sys.exit(1)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
    print(f"OK: {len(strings)} strings + {len(plurals)} plurals × {len(LANGS)} languages")


if __name__ == "__main__":
    main()
