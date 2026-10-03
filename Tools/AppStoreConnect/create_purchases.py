#!/usr/bin/env python3
"""Creates the Remote Pro in-app purchases in App Store Connect from the local StoreKit file.

What it sets up (from TVRemoteScreenMirroring/Resources/StoreKit/RemotePro.storekit):
  * the subscription group and its display name in every language of the file;
  * each auto-renewable subscription: reference name, product ID, period, level, family sharing,
    names and descriptions, availability in all territories, price (base: United States, other
    territories from Apple's equalized price points), a free-trial introductory offer if the file has one;
  * each non-consumable: same fields, price schedule with the US base price;
  * the App Review screenshot of every purchase (optional, --screenshot).

Safe to run again: anything that already exists is left as it is, only missing parts are added.
Offer codes from the file (bonus campaign, switched off) are NOT created.

Requires an App Store Connect API key (Users and Access → Integrations → App Store Connect API,
role App Manager or Admin). The .p8 file stays on your Mac; it is only read to sign requests.
Uses only the Python standard library and the system `openssl`.

Usage:
  python3 Tools/AppStoreConnect/create_purchases.py --key-id ABC123 --issuer-id 69a6de7e-... [--key-file path.p8]
      Dry run (default): reads App Store Connect and prints what would be created. Changes nothing.
  python3 Tools/AppStoreConnect/create_purchases.py ... --apply
      Creates what is missing.

Defaults: app ID from AppConfig.plist (AppStoreID); key file .appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
in the project folder (git-ignored), then ~/.appstoreconnect/private_keys/; review screenshot
Documentation/Screenshots/review/remote-pro-paywall.png. If the project key folder holds exactly one key, its
Key ID is taken from the file name, so only --issuer-id is needed. The key ID and issuer ID can also come from
the ASC_KEY_ID / ASC_ISSUER_ID environment variables.
"""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import plistlib
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[2]
KEY_DIRS = [ROOT / ".appstoreconnect/private_keys", pathlib.Path.home() / ".appstoreconnect/private_keys"]
STOREKIT = ROOT / "TVRemoteScreenMirroring/Resources/StoreKit/RemotePro.storekit"
APP_CONFIG = ROOT / "TVRemoteScreenMirroring/Resources/AppConfig.plist"
SCREENSHOT = ROOT / "Documentation/Screenshots/review/remote-pro-paywall.png"
BUNDLE_ID = "app.TVRemoteScreenMirroring"
API = os.environ.get("ASC_API_BASE", "https://api.appstoreconnect.apple.com")  # override only for tests
BASE_TERRITORY = "USA"

# StoreKit file locales → App Store Connect locales.
LOCALES = {"en_US": "en-US", "en": "en-US", "es_ES": "es-ES", "es": "es-ES", "ru": "ru", "ru_RU": "ru",
           "de": "de-DE", "de_DE": "de-DE", "fr": "fr-FR", "fr_FR": "fr-FR"}
PERIODS = {"P1W": "ONE_WEEK", "P1M": "ONE_MONTH", "P2M": "TWO_MONTHS", "P3M": "THREE_MONTHS",
           "P6M": "SIX_MONTHS", "P1Y": "ONE_YEAR"}
TRIAL_DURATIONS = {"P3D": "THREE_DAYS", "P1W": "ONE_WEEK", "P2W": "TWO_WEEKS", "P1M": "ONE_MONTH",
                   "P2M": "TWO_MONTHS", "P3M": "THREE_MONTHS", "P6M": "SIX_MONTHS", "P1Y": "ONE_YEAR"}
# App Store Connect limits for purchase metadata.
MAX_NAME, MAX_DESCRIPTION = 30, 45

REVIEW_NOTE = (
    "Remote Pro unlocks unlimited remote control, the phone keyboard, TV app shortcuts, photo and video "
    "casting and screen mirroring on supported TVs. The paywall can be reviewed without a TV: Settings → "
    "Remote Pro → Explore Pro. Prices, trial and terms are read from StoreKit."
)


class Stop(Exception):
    pass


def tls_context():
    """HTTPS trust for the Apple API. Python from python.org ships without root certificates
    (until "Install Certificates.command" is run), so fall back to the macOS system roots."""
    context = ssl.create_default_context()
    if context.cert_store_stats().get("x509_ca", 0) > 0:
        return context
    pem = ""
    for keychain in ("/System/Library/Keychains/SystemRootCertificates.keychain", "/Library/Keychains/System.keychain"):
        result = subprocess.run(["security", "find-certificate", "-a", "-p", keychain], capture_output=True, text=True)
        if result.returncode == 0:
            pem += result.stdout
    if not pem:
        raise Stop("No trusted root certificates: run “Install Certificates.command” from your Python folder in Applications.")
    context.load_verify_locations(cadata=pem)
    return context


# MARK: - Auth (ES256 JWT signed with the system openssl)

def _b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _der_to_raw(der):
    """ECDSA DER signature (SEQUENCE{INTEGER r, INTEGER s}) → 64-byte r||s used by JWT."""
    if der[0] != 0x30:
        raise Stop("Unexpected signature format from openssl")
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        if der[index] != 0x02:
            raise Stop("Unexpected signature format from openssl")
        length = der[index + 1]
        value = der[index + 2:index + 2 + length]
        parts.append(value.lstrip(b"\x00").rjust(32, b"\x00"))
        index += 2 + length
    return parts[0] + parts[1]


class Client:
    def __init__(self, key_id, issuer_id, key_file):
        self.key_id, self.issuer_id, self.key_file = key_id, issuer_id, key_file
        self._token, self._token_expiry = None, 0
        self.requests = 0
        self.tls = tls_context()

    def token(self):
        now = int(time.time())
        if self._token and now < self._token_expiry - 60:
            return self._token
        header = _b64url(json.dumps({"alg": "ES256", "kid": self.key_id, "typ": "JWT"}).encode())
        payload = _b64url(json.dumps({"iss": self.issuer_id, "iat": now, "exp": now + 1200,
                                      "aud": "appstoreconnect-v1"}).encode())
        signing_input = f"{header}.{payload}".encode()
        result = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(self.key_file)],
                                input=signing_input, capture_output=True)
        if result.returncode != 0:
            raise Stop("openssl could not sign with the key file: " + result.stderr.decode(errors="replace").strip())
        self._token = f"{header}.{payload}.{_b64url(_der_to_raw(result.stdout))}"
        self._token_expiry = now + 1200
        return self._token

    def request(self, method, path, body=None, query=None):
        url = path if path.startswith("http") else API + path
        if query:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(query)
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(6):
            req = urllib.request.Request(url, data=data, method=method, headers={
                "Authorization": f"Bearer {self.token()}", "Content-Type": "application/json"})
            self.requests += 1
            try:
                with urllib.request.urlopen(req, timeout=60, context=self.tls) as response:
                    raw = response.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as error:
                raw = error.read().decode(errors="replace")
                if error.code in (429, 500, 502, 503, 504) and attempt < 5:
                    time.sleep(2 ** attempt)
                    continue
                try:
                    details = "; ".join(f"{e.get('title')}: {e.get('detail')}" for e in json.loads(raw).get("errors", []))
                except ValueError:
                    details = raw[:500]
                raise Stop(f"{method} {urllib.parse.urlparse(url).path} → HTTP {error.code}. {details}")
            except urllib.error.URLError as error:
                if attempt < 5:
                    time.sleep(2 ** attempt)
                    continue
                raise Stop(f"Network error: {error.reason}")
        raise Stop("Too many retries")

    def get_all(self, path, query=None):
        """Follows `links.next` and returns (data, included)."""
        data, included = [], []
        response = self.request("GET", path, query=query)
        while True:
            data += response.get("data") or []
            included += response.get("included") or []
            next_url = (response.get("links") or {}).get("next")
            if not next_url:
                return data, included
            response = self.request("GET", next_url)


# MARK: - Helpers

def rel(type_, id_):
    return {"data": {"type": type_, "id": id_}}


def territory_of(item):
    """Territory code of a price point / price / offer (relationship, or the encoded ID as a fallback)."""
    territory = ((item.get("relationships") or {}).get("territory") or {}).get("data")
    if territory:
        return territory["id"]
    try:
        raw = item["id"] + "=" * (-len(item["id"]) % 4)
        return json.loads(base64.urlsafe_b64decode(raw)).get("t")
    except (ValueError, KeyError):
        return None


def price_value(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def choose_price_point(points, wanted):
    """Exact customer price if Apple offers it, otherwise the nearest one (reported)."""
    target = float(wanted)
    priced = [(p, price_value(p["attributes"].get("customerPrice"))) for p in points]
    priced = [(p, v) for p, v in priced if v is not None]
    if not priced:
        raise Stop("No price points returned for the base territory")
    exact = [p for p, v in priced if abs(v - target) < 0.001]
    if exact:
        return exact[0], True
    nearest = min(priced, key=lambda pv: (abs(pv[1] - target), pv[1]))
    return nearest[0], False


def neighbours(points, wanted):
    """The Apple prices just below and above the wanted one (for the error message)."""
    values = sorted({v for v in (price_value(p["attributes"].get("customerPrice")) for p in points) if v is not None})
    target = float(wanted)
    below = [v for v in values if v < target][-1:]
    above = [v for v in values if v > target][:1]
    return ", ".join(f"{v:.2f}" for v in below + above)


class Runner:
    def __init__(self, client, app_id, apply, screenshot, accept_nearest):
        self.client, self.app_id, self.apply, self.screenshot = client, app_id, apply, screenshot
        self.accept_nearest = accept_nearest
        self.territories = None
        self.planned = 0

    def log(self, symbol, text):
        print(f"  {symbol} {text}")

    def create(self, description, path, body):
        """POST when applying; in a dry run only reports. Returns the created object or None."""
        self.planned += 1
        if not self.apply:
            self.log("+", f"would create {description}")
            return None
        response = self.client.request("POST", path, body=body)
        self.log("+", f"created {description}")
        return response.get("data")

    def all_territories(self):
        if self.territories is None:
            data, _ = self.client.get_all("/v1/territories", {"limit": 200})
            self.territories = sorted(t["id"] for t in data)
        return self.territories

    # MARK: App

    def check_app(self):
        app = self.client.request("GET", f"/v1/apps/{self.app_id}")["data"]
        bundle = app["attributes"].get("bundleId")
        print(f"App: {app['attributes'].get('name')} ({bundle}), ID {self.app_id}")
        if bundle != BUNDLE_ID:
            raise Stop(f"This App Store Connect app has bundle ID {bundle}, the project uses {BUNDLE_ID}. Check --app-id.")

    # MARK: Subscriptions

    def subscription_group(self, group):
        name = group["name"]
        print(f"\nSubscription group “{name}”")
        groups, _ = self.client.get_all(f"/v1/apps/{self.app_id}/subscriptionGroups", {"limit": 200})
        existing = next((g for g in groups if g["attributes"].get("referenceName") == name), None)
        if existing:
            self.log("=", "group exists")
            group_id = existing["id"]
        else:
            created = self.create("subscription group", "/v1/subscriptionGroups", {"data": {
                "type": "subscriptionGroups", "attributes": {"referenceName": name},
                "relationships": {"app": rel("apps", self.app_id)}}})
            group_id = created["id"] if created else None

        # Display name of the group in each language (shown in the App Store subscription settings).
        locales = sorted({LOCALES[l["locale"]] for s in group["subscriptions"] for l in s["localizations"]})
        have = set()
        if group_id:
            data, _ = self.client.get_all(f"/v1/subscriptionGroups/{group_id}/subscriptionGroupLocalizations", {"limit": 200})
            have = {d["attributes"]["locale"] for d in data}
        for locale in locales:
            if locale in have:
                continue
            self.create(f"group name ({locale})", "/v1/subscriptionGroupLocalizations", {"data": {
                "type": "subscriptionGroupLocalizations", "attributes": {"name": name, "locale": locale},
                "relationships": {"subscriptionGroup": rel("subscriptionGroups", group_id or "NEW")}}})
        return group_id

    def subscription(self, group_id, item):
        product_id = item["productID"]
        print(f"\nSubscription {product_id} — {item['displayPrice']} USD, {item['recurringSubscriptionPeriod']}")
        existing = None
        if group_id:
            subs, _ = self.client.get_all(f"/v1/subscriptionGroups/{group_id}/subscriptions", {"limit": 200})
            existing = next((s for s in subs if s["attributes"].get("productId") == product_id), None)
        if existing:
            self.log("=", f"exists (state: {existing['attributes'].get('state')})")
            sub_id = existing["id"]
        else:
            period = PERIODS.get(item["recurringSubscriptionPeriod"])
            if not period:
                raise Stop(f"Unsupported period {item['recurringSubscriptionPeriod']}")
            created = self.create("subscription", "/v1/subscriptions", {"data": {
                "type": "subscriptions",
                "attributes": {"name": item["referenceName"], "productId": product_id, "subscriptionPeriod": period,
                               "groupLevel": item.get("groupNumber", 1), "familySharable": bool(item.get("familyShareable")),
                               "reviewNote": REVIEW_NOTE},
                "relationships": {"group": rel("subscriptionGroups", group_id or "NEW")}}})
            sub_id = created["id"] if created else None

        self.localizations(item, sub_id, f"/v1/subscriptions/{sub_id}/subscriptionLocalizations",
                           "/v1/subscriptionLocalizations", "subscriptionLocalizations",
                           {"subscription": rel("subscriptions", sub_id or "NEW")})
        self.subscription_availability(sub_id)
        self.subscription_prices(sub_id, item["displayPrice"])
        offer = item.get("introductoryOffer")
        if offer:
            self.free_trial(sub_id, offer)
        self.review_screenshot(sub_id, f"/v1/subscriptions/{sub_id}/appStoreReviewScreenshot",
                               "/v1/subscriptionAppStoreReviewScreenshots", "subscriptionAppStoreReviewScreenshots",
                               {"subscription": rel("subscriptions", sub_id or "NEW")})

    def subscription_availability(self, sub_id):
        if sub_id:
            try:
                current = self.client.request("GET", f"/v1/subscriptions/{sub_id}/subscriptionAvailability").get("data")
            except Stop:
                current = None
            if current:
                self.log("=", "availability set")
                return
        territories = self.all_territories()
        self.create(f"availability in {len(territories)} territories (and new ones)", "/v1/subscriptionAvailabilities", {"data": {
            "type": "subscriptionAvailabilities", "attributes": {"availableInNewTerritories": True},
            "relationships": {"subscription": rel("subscriptions", sub_id or "NEW"),
                              "availableTerritories": {"data": [{"type": "territories", "id": t} for t in territories]}}}})

    def subscription_prices(self, sub_id, wanted):
        if not sub_id:
            self.planned += 1
            self.log("+", f"would set price {wanted} USD and Apple’s equalized prices in every other territory")
            return
        prices, _ = self.client.get_all(f"/v1/subscriptions/{sub_id}/prices", {"include": "territory", "limit": 200})
        priced = {territory_of(p) for p in prices}
        points, _ = self.client.get_all(f"/v1/subscriptions/{sub_id}/pricePoints",
                                        {"filter[territory]": BASE_TERRITORY, "limit": 200})
        base, exact = choose_price_point(points, wanted)
        actual = base["attributes"]["customerPrice"]
        if not exact:
            self.price_mismatch(wanted, actual, points)
        targets = [(BASE_TERRITORY, base["id"])]
        equal, _ = self.client.get_all(f"/v1/subscriptionPricePoints/{base['id']}/equalizations",
                                       {"include": "territory", "limit": 200})
        targets += [(territory_of(p), p["id"]) for p in equal if territory_of(p)]
        missing = [(t, pp) for t, pp in targets if t not in priced]
        if not missing:
            self.log("=", f"prices set in {len(priced)} territories")
            return
        others = sum(1 for territory, _ in missing if territory != BASE_TERRITORY)
        self.log("+", f"{'setting' if self.apply else 'would set'} price {actual} USD in {BASE_TERRITORY} "
                      f"and Apple’s equalized prices in {others} more territories")
        self.planned += 1
        if not self.apply:
            return
        for index, (territory, point_id) in enumerate(missing, 1):
            self.client.request("POST", "/v1/subscriptionPrices", body={"data": {
                "type": "subscriptionPrices", "attributes": {"preserveCurrentPrice": False},
                "relationships": {"subscription": rel("subscriptions", sub_id),
                                  "subscriptionPricePoint": rel("subscriptionPricePoints", point_id)}}})
            if index % 25 == 0:
                print(f"      {index}/{len(missing)}")

    def free_trial(self, sub_id, offer):
        if offer.get("paymentMode") != "free":
            self.log("!", f"introductory offer {offer.get('paymentMode')} is not a free trial — set it up manually")
            return
        duration = TRIAL_DURATIONS.get(offer.get("subscriptionPeriod"))
        if not duration:
            raise Stop(f"Unsupported trial period {offer.get('subscriptionPeriod')}")
        territories = self.all_territories()
        have = set()
        if sub_id:
            offers, _ = self.client.get_all(f"/v1/subscriptions/{sub_id}/introductoryOffers", {"include": "territory", "limit": 200})
            have = {territory_of(o) for o in offers}
        missing = [t for t in territories if t not in have]
        if not missing:
            self.log("=", f"free trial ({duration}) set")
            return
        self.planned += 1
        self.log("+", f"{'adding' if self.apply else 'would add'} free trial {duration} for new subscribers in {len(missing)} territories")
        if not self.apply:
            return
        for index, territory in enumerate(missing, 1):
            self.client.request("POST", "/v1/subscriptionIntroductoryOffers", body={"data": {
                "type": "subscriptionIntroductoryOffers",
                "attributes": {"duration": duration, "offerMode": "FREE_TRIAL", "numberOfPeriods": int(offer.get("numberOfPeriods", 1))},
                "relationships": {"subscription": rel("subscriptions", sub_id), "territory": rel("territories", territory)}}})
            if index % 25 == 0:
                print(f"      {index}/{len(missing)}")

    # MARK: Non-consumable

    def non_consumable(self, item):
        product_id = item["productID"]
        print(f"\nOne-time purchase {product_id} — {item['displayPrice']} USD")
        found, _ = self.client.get_all(f"/v1/apps/{self.app_id}/inAppPurchasesV2",
                                       {"filter[productId]": product_id, "limit": 200})
        existing = next((i for i in found if i["attributes"].get("productId") == product_id), None)
        if existing:
            self.log("=", f"exists (state: {existing['attributes'].get('state')})")
            iap_id = existing["id"]
        else:
            created = self.create("non-consumable", "/v2/inAppPurchases", {"data": {
                "type": "inAppPurchases",
                "attributes": {"name": item["referenceName"], "productId": product_id, "inAppPurchaseType": "NON_CONSUMABLE",
                               "familySharable": bool(item.get("familyShareable")), "reviewNote": REVIEW_NOTE},
                "relationships": {"app": rel("apps", self.app_id)}}})
            iap_id = created["id"] if created else None

        self.localizations(item, iap_id, f"/v2/inAppPurchases/{iap_id}/inAppPurchaseLocalizations",
                           "/v1/inAppPurchaseLocalizations", "inAppPurchaseLocalizations",
                           {"inAppPurchaseV2": rel("inAppPurchases", iap_id or "NEW")})

        # Availability
        current = None
        if iap_id:
            try:
                current = self.client.request("GET", f"/v2/inAppPurchases/{iap_id}/inAppPurchaseAvailability").get("data")
            except Stop:
                current = None
        if current:
            self.log("=", "availability set")
        else:
            territories = self.all_territories()
            self.create(f"availability in {len(territories)} territories (and new ones)", "/v1/inAppPurchaseAvailabilities", {"data": {
                "type": "inAppPurchaseAvailabilities", "attributes": {"availableInNewTerritories": True},
                "relationships": {"inAppPurchase": rel("inAppPurchases", iap_id or "NEW"),
                                  "availableTerritories": {"data": [{"type": "territories", "id": t} for t in territories]}}}})

        # Price schedule: US base price; Apple derives the other territories.
        schedule = None
        if iap_id:
            try:
                schedule = self.client.request("GET", f"/v2/inAppPurchases/{iap_id}/iapPriceSchedule").get("data")
            except Stop:
                schedule = None
        if schedule:
            self.log("=", "price schedule set")
        elif not iap_id:
            self.planned += 1
            self.log("+", f"would set price {item['displayPrice']} USD (other territories derived by Apple)")
        else:
            points, _ = self.client.get_all(f"/v2/inAppPurchases/{iap_id}/pricePoints",
                                            {"filter[territory]": BASE_TERRITORY, "limit": 200})
            point, exact = choose_price_point(points, item["displayPrice"])
            actual = point["attributes"]["customerPrice"]
            if not exact:
                self.price_mismatch(item["displayPrice"], actual, points)
            self.create(f"price {actual} USD (other territories derived by Apple)", "/v1/inAppPurchasePriceSchedules", {
                "data": {"type": "inAppPurchasePriceSchedules", "relationships": {
                    "inAppPurchase": rel("inAppPurchases", iap_id),
                    "baseTerritory": rel("territories", BASE_TERRITORY),
                    "manualPrices": {"data": [{"type": "inAppPurchasePrices", "id": "${base}"}]}}},
                "included": [{"type": "inAppPurchasePrices", "id": "${base}", "attributes": {"startDate": None},
                              "relationships": {"inAppPurchaseV2": rel("inAppPurchases", iap_id),
                                                "inAppPurchasePricePoint": rel("inAppPurchasePricePoints", point["id"])}}]})

        self.review_screenshot(iap_id, f"/v2/inAppPurchases/{iap_id}/appStoreReviewScreenshot",
                               "/v1/inAppPurchaseAppStoreReviewScreenshots", "inAppPurchaseAppStoreReviewScreenshots",
                               {"inAppPurchaseV2": rel("inAppPurchases", iap_id or "NEW")})

    # MARK: Shared

    def price_mismatch(self, wanted, actual, points):
        """Apple has no such price: never pick another one silently."""
        message = f"{wanted} USD is not an Apple price point (nearest: {neighbours(points, wanted)} USD)"
        if self.apply and not self.accept_nearest:
            raise Stop(message + ". Change the price in the StoreKit file to one of these, "
                       f"or rerun with --accept-nearest-price to use {actual} USD.")
        self.log("!", message + f"; {'using' if self.apply else 'would use'} {actual} USD")

    def localizations(self, item, owner_id, list_path, create_path, type_, relationship):
        have = set()
        if owner_id:
            data, _ = self.client.get_all(list_path, {"limit": 200})
            have = {d["attributes"]["locale"] for d in data}
        for loc in item["localizations"]:
            locale = LOCALES[loc["locale"]]
            if locale in have:
                continue
            self.create(f"name and description ({locale}): {loc['displayName']}", create_path, {"data": {
                "type": type_, "attributes": {"name": loc["displayName"], "description": loc["description"], "locale": locale},
                "relationships": relationship}})
        if have and all(LOCALES[l["locale"]] in have for l in item["localizations"]):
            self.log("=", f"texts in {len(have)} languages")

    def review_screenshot(self, owner_id, get_path, create_path, type_, relationship):
        if not self.screenshot:
            return
        if owner_id:
            try:
                current = self.client.request("GET", get_path).get("data")
            except Stop:
                current = None
            state = (((current or {}).get("attributes") or {}).get("assetDeliveryState") or {}).get("state")
            if current and state != "FAILED":
                self.log("=", "review screenshot uploaded")
                return
        data = self.screenshot.read_bytes()
        created = self.create(f"App Review screenshot ({self.screenshot.name})", create_path, {"data": {
            "type": type_, "attributes": {"fileName": self.screenshot.name, "fileSize": len(data)},
            "relationships": relationship}})
        if not created:
            return
        for operation in created["attributes"].get("uploadOperations") or []:
            chunk = data[operation["offset"]:operation["offset"] + operation["length"]]
            headers = {h["name"]: h["value"] for h in operation.get("requestHeaders") or []}
            request = urllib.request.Request(operation["url"], data=chunk, method=operation["method"], headers=headers)
            with urllib.request.urlopen(request, timeout=120, context=self.client.tls):
                pass
        self.client.request("PATCH", f"{create_path}/{created['id']}", body={"data": {
            "type": type_, "id": created["id"],
            "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})


# MARK: - Validation of the StoreKit file

def load_storekit():
    config = json.loads(STOREKIT.read_text(encoding="utf-8"))
    problems = []
    items = [s for g in config.get("subscriptionGroups", []) for s in g["subscriptions"]] + config.get("products", [])
    for item in items:
        for loc in item.get("localizations", []):
            if loc["locale"] not in LOCALES:
                problems.append(f"{item['productID']}: unknown locale {loc['locale']}")
            if len(loc["displayName"]) > MAX_NAME:
                problems.append(f"{item['productID']} [{loc['locale']}]: name longer than {MAX_NAME}: {loc['displayName']}")
            if len(loc["description"]) > MAX_DESCRIPTION:
                problems.append(f"{item['productID']} [{loc['locale']}]: description longer than {MAX_DESCRIPTION}: {loc['description']}")
    for product in config.get("products", []):
        if product.get("type") != "NonConsumable":
            problems.append(f"{product['productID']}: only non-consumables are supported here ({product.get('type')})")
    if problems:
        raise Stop("StoreKit file needs fixing first:\n  " + "\n  ".join(problems))
    return config


def check_product_ids(config):
    """Product IDs in the StoreKit file must be the ones the app asks StoreKit for."""
    with open(APP_CONFIG, "rb") as f:
        products = plistlib.load(f).get("Products", {})
    expected = {products.get(k) for k in ("Monthly", "Yearly", "Lifetime")} - {None, ""}
    found = {s["productID"] for g in config.get("subscriptionGroups", []) for s in g["subscriptions"]}
    found |= {p["productID"] for p in config.get("products", [])}
    if expected != found:
        raise Stop(f"Product IDs differ: AppConfig.plist {sorted(expected)} vs StoreKit file {sorted(found)}")


def main():
    parser = argparse.ArgumentParser(description="Create Remote Pro purchases in App Store Connect from the StoreKit file.")
    parser.add_argument("--key-id", default=os.environ.get("ASC_KEY_ID"), help="App Store Connect API key ID")
    parser.add_argument("--issuer-id", default=os.environ.get("ASC_ISSUER_ID"), help="Issuer ID (Users and Access → Integrations)")
    parser.add_argument("--key-file", help="Path to AuthKey_<KEY_ID>.p8 (default: <project>/.appstoreconnect/private_keys/, "
                                           "then ~/.appstoreconnect/private_keys/)")
    parser.add_argument("--app-id", help="Apple ID of the app (default: AppStoreID in AppConfig.plist)")
    parser.add_argument("--screenshot", default=str(SCREENSHOT), help="App Review screenshot (PNG/JPEG); pass '' to skip")
    parser.add_argument("--apply", action="store_true", help="Actually create what is missing (default: dry run)")
    parser.add_argument("--accept-nearest-price", action="store_true",
                        help="If a price from the StoreKit file isn't an Apple price point, use the nearest one")
    args = parser.parse_args()

    try:
        config = load_storekit()
        check_product_ids(config)
        key_id = args.key_id
        if not key_id and not args.key_file:
            # One key in the project's key folder: its file name carries the Key ID.
            keys = sorted(KEY_DIRS[0].glob("AuthKey_*.p8")) if KEY_DIRS[0].is_dir() else []
            if len(keys) == 1:
                key_id = keys[0].stem.removeprefix("AuthKey_")
        if args.key_file and not key_id:
            key_id = pathlib.Path(args.key_file).stem.removeprefix("AuthKey_")
        if not key_id or not args.issuer_id:
            raise Stop("Pass --issuer-id (and --key-id if the key isn't the only one in .appstoreconnect/private_keys), "
                       "or set ASC_ISSUER_ID / ASC_KEY_ID.")
        if args.key_file:
            key_file = pathlib.Path(args.key_file).expanduser()
        else:
            key_file = next((d / f"AuthKey_{key_id}.p8" for d in KEY_DIRS if (d / f"AuthKey_{key_id}.p8").is_file()),
                            KEY_DIRS[0] / f"AuthKey_{key_id}.p8")
        if not key_file.is_file():
            raise Stop(f"Key file not found: {key_file}")
        print(f"Key: {key_file.relative_to(ROOT) if key_file.is_relative_to(ROOT) else key_file} (Key ID {key_id})")
        with open(APP_CONFIG, "rb") as f:
            app_id = args.app_id or str(plistlib.load(f).get("AppStoreID") or "")
        if not app_id:
            raise Stop("No app ID: pass --app-id or fill AppStoreID in AppConfig.plist.")
        screenshot = pathlib.Path(args.screenshot) if args.screenshot else None
        if screenshot and not screenshot.is_file():
            raise Stop(f"Screenshot not found: {screenshot}")

        print("MODE: APPLY — changes will be made in App Store Connect" if args.apply
              else "MODE: DRY RUN — nothing will be changed (add --apply to create)")
        client = Client(key_id, args.issuer_id, key_file)
        runner = Runner(client, app_id, args.apply, screenshot, args.accept_nearest_price)
        runner.check_app()
        for group in config.get("subscriptionGroups", []):
            group_id = runner.subscription_group(group)
            for item in sorted(group["subscriptions"], key=lambda s: s["productID"]):
                runner.subscription(group_id, item)
        for product in config.get("products", []):
            runner.non_consumable(product)
        if config.get("subscriptionGroups") and any(s.get("codeOffers") for g in config["subscriptionGroups"] for s in g["subscriptions"]):
            print("\nOffer codes in the StoreKit file (bonus campaign) were skipped: the campaign is switched off.")

        print(f"\n{'Done' if args.apply else 'Dry run finished'}: {runner.planned} step(s) "
              f"{'applied' if args.apply else 'to apply'}, {client.requests} API requests.")
        if not args.apply and runner.planned:
            print("Run again with --apply to create them.")
        if args.apply:
            print("Next in App Store Connect: sign the Paid Apps agreement (Business), check each purchase shows "
                  "“Ready to Submit”, and select all three on the version page when you submit the app.")
    except Stop as error:
        sys.stdout.flush()
        print(f"\nStopped: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nInterrupted. Run again: existing items are skipped.", file=sys.stderr)
        sys.exit(130)


if __name__ == "__main__":
    main()
