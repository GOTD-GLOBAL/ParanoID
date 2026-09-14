"""F4 source wiring only; not a substitute for InterruptedOnboardingTests on macOS.

REQ-ID-005/008, SS-01, RFC-0021 / proposed ADR-0014. Run on Linux with:
python3 clients/ios/test_interrupted_onboarding_contract.py
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent / "ParanoidKit/Sources/ParanoidKit/Service"


def body(source, declaration):
    start = source.index(declaration)
    start = source.index("{", start)
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return re.sub(r"//[^\n]*", "", source[start + 1:end - 1])


class InterruptedOnboardingContract(unittest.TestCase):
    def test_retained_schema_zero_is_committed_before_registration(self):
        client = (ROOT / "SelfServiceClient.swift").read_text()
        flow = (ROOT / "ProofFlow.swift").read_text()
        self.assertIn("func resumeOnboarding() throws", client,
                      "F4: dry-run open needs a durable onboarding continuation")
        resume = body(client, "func resumeOnboarding() throws")
        self.assertIn("try healthy()", resume)
        self.assertRegex(resume, r"guard\s+!state.isEmpty\s+else\s*\{\s*return\s*\}")
        self.assertRegex(resume, r'if stateVersion == Snapshot.legacyStateVersion\s*\{\s*try apply\(\["op": "upgrade_v2"\]\)')
        self.assertNotIn('"create_identity"', resume)
        connection = body(flow, "private func connection(under")
        self.assertIn("try $0.resumeOnboarding()", connection)
        self.assertLess(connection.index("hasIdentity()"), connection.index("resumeOnboarding()"))
        self.assertLess(connection.index("resumeOnboarding()"), connection.index("registered()"))
        self.assertLess(connection.index("resumeOnboarding()"), connection.index("await proof("))
        opening = body(client, "public init(saved:")
        self.assertIn("try dryRunUpgrade()", opening)
        self.assertNotIn("resumeOnboarding()", opening)
        self.assertNotIn("try apply", opening)


    def test_active_checkpoint_prepares_contact_without_registration(self):
        client = (ROOT / "SelfServiceClient.swift").read_text()
        resume = body(client, "func resumeOnboarding() throws")
        self.assertRegex(resume, r'if try active\(\)\s*\{\s*try apply\(\["op": "prepare_contact_v2"\]\)',
                         "F4: active enrollment still needs durable contact preparation")
        self.assertNotIn('"server_status_v2"', resume)
        self.assertNotIn("sink.save", resume, "resume must use the existing guarded apply path")
        apply = body(client, "private func apply(")
        self.assertLess(apply.index("try sink.save(wrapper.text)"), apply.index("state = next"))
        self.assertIn("isBroken = true", apply)
        self.assertIn("throw SelfServiceError.commitFailed", apply)


if __name__ == "__main__":
    unittest.main()
