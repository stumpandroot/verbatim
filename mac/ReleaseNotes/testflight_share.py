#!/usr/bin/env python3
"""Shares a TestFlight build with external testers through a public link. See README.md in this folder.

  share --build N.1 [--group Friends] [--feedback-email ADDRESS] [--bundle-id co.stumpandroot.verbatim.ios]
        [--timeout 1200] [--interval 30]
      CI, after the public TestFlight upload (.github/workflows/build-swift.yml, the testflight job's public track):
      waits until App Store Connect has processed the build, makes sure the external group exists with its public link
      on, makes sure the app's beta description and feedback address are filled in, adds the build to the group, and
      submits it for Beta App Review. Prints the public link. The key comes from the environment, as for
      testflight_what_to_test.py: ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH. Exits 1 with a reason on any problem;
      the workflow step turns that into a warning.
  share-check
      The test (tools/test-release-notes.sh): runs the same steps against a stand-in for App Store Connect.

Only builds made without YOUTUBE_ON_DEVICE may come here (mac/APP_STORE.md): external testing goes through review.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from testflight_what_to_test import BUNDLE_ID, Client, Problem, find_app, wait_for_build, valid_build  # noqa: E402

GROUP = "Friends"
LOCALE = "en-US"
DESCRIPTION = ("Verbose turns what you say into text you can use. Record a voice memo, a meeting, or a lecture, import "
               "audio or video, or dictate into any app with the Verbose keyboard. Transcription runs on your iPhone.")


def find_or_make_group(api, app_id, name):
    """The external group's ID and public link, made (or switched to a public link) when needed."""
    found = api.call("GET", "/v1/betaGroups", {"filter[app]": app_id, "filter[name]": name,
                                                "fields[betaGroups]": "name,isInternalGroup,publicLinkEnabled,publicLink",
                                                "limit": "10"}).get("data", [])
    g = next((x for x in found if x.get("attributes", {}).get("name") == name
              and not x.get("attributes", {}).get("isInternalGroup")), None)
    if g is None:
        g = api.call("POST", "/v1/betaGroups", body={"data": {
            "type": "betaGroups",
            "attributes": {"name": name, "publicLinkEnabled": True, "publicLinkLimitEnabled": False, "feedbackEnabled": True},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})["data"]
        print("Made the external group %s" % name)
    elif not g.get("attributes", {}).get("publicLinkEnabled"):
        g = api.call("PATCH", "/v1/betaGroups/%s" % g["id"], body={"data": {
            "type": "betaGroups", "id": g["id"], "attributes": {"publicLinkEnabled": True, "publicLinkLimitEnabled": False}}})["data"]
        print("Turned on the public link for %s" % name)
    return g["id"], g.get("attributes", {}).get("publicLink")


def fill_test_information(api, app_id, feedback_email):
    """The beta description and feedback address external testing needs, when they're empty. Returns what it filled."""
    filled = []
    locs = api.call("GET", "/v1/apps/%s/betaAppLocalizations" % app_id,
                    {"fields[betaAppLocalizations]": "locale,description,feedbackEmail", "limit": "50"}).get("data", [])
    loc = next((x for x in locs if x.get("attributes", {}).get("locale") == LOCALE), None)
    if loc is None:
        api.call("POST", "/v1/betaAppLocalizations", body={"data": {
            "type": "betaAppLocalizations",
            "attributes": {"locale": LOCALE, "description": DESCRIPTION, "feedbackEmail": feedback_email},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
        filled += ["description", "feedback email"]
    else:
        a = loc.get("attributes", {})
        change = {}
        if not (a.get("description") or "").strip():
            change["description"] = DESCRIPTION
            filled.append("description")
        if not (a.get("feedbackEmail") or "").strip():
            change["feedbackEmail"] = feedback_email
            filled.append("feedback email")
        if change:
            api.call("PATCH", "/v1/betaAppLocalizations/%s" % loc["id"], body={"data": {
                "type": "betaAppLocalizations", "id": loc["id"], "attributes": change}})
    return filled


def missing_review_contact(api, app_id):
    """The Beta App Review contact fields that are empty. Only you can fill in the phone number, so this names them."""
    d = api.call("GET", "/v1/apps/%s/betaAppReviewDetail" % app_id,
                 {"fields[betaAppReviewDetails]": "contactFirstName,contactLastName,contactPhone,contactEmail"}).get("data") or {}
    a = d.get("attributes", {})
    names = {"contactFirstName": "first name", "contactLastName": "last name", "contactPhone": "phone", "contactEmail": "email"}
    return [label for key, label in names.items() if not (a.get(key) or "").strip()]


def add_and_submit(api, group_id, build_id):
    """Adds the build to the group and submits it for Beta App Review. Returns "submitted" or "already submitted"."""
    api.call("POST", "/v1/betaGroups/%s/relationships/builds" % group_id,
             body={"data": [{"type": "builds", "id": build_id}]})
    try:
        api.call("POST", "/v1/betaAppReviewSubmissions", body={"data": {
            "type": "betaAppReviewSubmissions",
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
        return "submitted"
    except Problem as e:
        # A build that's in review or approved already answers 409.
        if "HTTP 409" in str(e):
            return "already submitted"
        raise


def share(api, bundle_id, build, group, feedback_email, timeout, interval, **wait):
    app_id = find_app(api, bundle_id)
    build_id = wait_for_build(api, app_id, build, timeout, interval, **wait)
    group_id, link = find_or_make_group(api, app_id, group)
    filled = fill_test_information(api, app_id, feedback_email)
    if filled:
        print("Filled in TestFlight's Test Information: %s" % ", ".join(filled))
    missing = missing_review_contact(api, app_id)
    if missing:
        # Adding the build still works; the submission would fail without a contact, so say what's needed instead.
        api.call("POST", "/v1/betaGroups/%s/relationships/builds" % group_id, body={"data": [{"type": "builds", "id": build_id}]})
        raise Problem("build %s is in %s but wasn't sent for Beta App Review: fill in the review contact's %s in App Store "
                      "Connect › TestFlight › Test Information, once" % (build, group, ", ".join(missing)))
    how = add_and_submit(api, group_id, build_id)
    print("Build %s added to %s and %s for Beta App Review" % (build, group, how))
    if link:
        print("Public link: %s" % link)
    return link


class FakeAPI:
    """App Store Connect as share-check needs it: one app, one processed build, and whatever the test sets up."""
    def __init__(self, group=None, locs=None, contact=None, submitted=False):
        self.calls, self.group, self.locs, self.contact, self.submitted = [], group, locs or [], contact or {}, submitted

    def call(self, method, path, query=None, body=None):
        self.calls.append((method, path))
        if path == "/v1/apps":
            return {"data": [{"id": "APP", "attributes": {"bundleId": BUNDLE_ID}}]}
        if path == "/v1/builds":
            return {"data": [{"id": "B1", "attributes": {"version": query["filter[version]"], "processingState": "VALID"}}]}
        if path == "/v1/betaGroups" and method == "GET":
            return {"data": [self.group] if self.group else []}
        if path == "/v1/betaGroups" and method == "POST":
            self.group = {"id": "G1", "attributes": dict(body["data"]["attributes"], publicLink="https://testflight.apple.com/join/TEST")}
            return {"data": self.group}
        if path.startswith("/v1/betaGroups/") and method == "PATCH":
            self.group["attributes"].update(body["data"]["attributes"], publicLink="https://testflight.apple.com/join/TEST")
            return {"data": self.group}
        if path.endswith("/betaAppLocalizations"):
            return {"data": self.locs}
        if path in ("/v1/betaAppLocalizations",) or path.startswith("/v1/betaAppLocalizations/"):
            return {"data": {"id": "L1"}}
        if path.endswith("/betaAppReviewDetail"):
            return {"data": {"id": "R1", "attributes": self.contact}}
        if path.endswith("/relationships/builds"):
            return {}
        if path == "/v1/betaAppReviewSubmissions":
            if self.submitted:
                raise Problem("POST /v1/betaAppReviewSubmissions: HTTP 409 already submitted")
            return {"data": {"id": "S1"}}
        raise AssertionError("unexpected call %s %s" % (method, path))


def share_check():
    full = {"contactFirstName": "A", "contactLastName": "B", "contactPhone": "1", "contactEmail": "a@b.c"}
    run = lambda api: share(api, BUNDLE_ID, "250.1", GROUP, "feedback@example.com", 60, 1, clock=lambda: 0, sleep=lambda s: None)

    # A first run: no group, no Test Information. It makes both, adds the build, and submits it.
    api = FakeAPI(contact=full)
    assert run(api) == "https://testflight.apple.com/join/TEST"
    assert ("POST", "/v1/betaGroups") in api.calls and ("POST", "/v1/betaAppLocalizations") in api.calls, api.calls
    assert ("POST", "/v1/betaGroups/G1/relationships/builds") in api.calls and ("POST", "/v1/betaAppReviewSubmissions") in api.calls

    # A later run: the group is there with its link, the description is filled in. Nothing is made or changed.
    g = {"id": "G1", "attributes": {"name": GROUP, "isInternalGroup": False, "publicLinkEnabled": True, "publicLink": "https://testflight.apple.com/join/TEST"}}
    loc = {"id": "L1", "attributes": {"locale": LOCALE, "description": "x", "feedbackEmail": "y"}}
    api = FakeAPI(group=g, locs=[loc], contact=full, submitted=True)
    run(api)
    assert not any(m in ("PATCH",) or p in ("/v1/betaGroups", "/v1/betaAppLocalizations") and m == "POST" for m, p in api.calls), api.calls

    # The group exists without a public link: it's switched on.
    off = {"id": "G1", "attributes": {"name": GROUP, "isInternalGroup": False, "publicLinkEnabled": False}}
    api = FakeAPI(group=off, locs=[loc], contact=full)
    assert run(api) == "https://testflight.apple.com/join/TEST"
    assert ("PATCH", "/v1/betaGroups/G1") in api.calls

    # An internal group with the same name is never used.
    internal = {"id": "G0", "attributes": {"name": GROUP, "isInternalGroup": True}}
    api = FakeAPI(group=internal, locs=[loc], contact=full)
    run(api)
    assert ("POST", "/v1/betaGroups") in api.calls

    # No phone for the review contact: the build joins the group, isn't submitted, and the reason names the phone.
    api = FakeAPI(group=g, locs=[loc], contact=dict(full, contactPhone=""))
    try:
        run(api)
        raise AssertionError("expected a Problem")
    except Problem as e:
        assert "phone" in str(e) and "Test Information" in str(e), e
    assert ("POST", "/v1/betaAppReviewSubmissions") not in api.calls

    # The build numbers this takes.
    assert valid_build("250") and valid_build("250.1") and not valid_build("250.x") and not valid_build("")
    print("share-check: public link steps pass")
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("share", help="share a build through the external group's public link")
    s.add_argument("--build", required=True, help="the build number (CFBundleVersion), such as 250.1")
    s.add_argument("--group", default=GROUP)
    s.add_argument("--feedback-email", required=True)
    s.add_argument("--bundle-id", default=BUNDLE_ID)
    s.add_argument("--timeout", type=int, default=1200)
    s.add_argument("--interval", type=int, default=30)
    sub.add_parser("share-check", help="run the steps against a stand-in for App Store Connect")
    a = p.parse_args(argv)
    if a.cmd == "share-check":
        return share_check()
    try:
        if not valid_build(a.build):
            raise Problem("%r isn't a build number" % a.build)
        key_id = os.environ.get("ASC_KEY_ID", "").strip()
        issuer = os.environ.get("ASC_ISSUER_ID", "").strip()
        key_path = os.environ.get("ASC_KEY_PATH", "")
        if not key_id or not issuer or not os.path.isfile(key_path):
            raise Problem("ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH must be set")
        share(Client(key_id, issuer, key_path), a.bundle_id, a.build, a.group, a.feedback_email, a.timeout, a.interval)
        return 0
    except (Problem, OSError) as e:
        print("Build %s wasn't shared: %s" % (a.build, e), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
