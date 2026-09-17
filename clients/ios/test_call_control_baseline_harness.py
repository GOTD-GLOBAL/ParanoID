"""Unit fixtures for the RED-receipt classifier; NOT Swift execution."""
import unittest
from test_call_control_baseline import behavioral_red


class BaselineReceiptClassifier(unittest.TestCase):
    def test_accepts_executed_behavioral_failure(self):
        fixture = ("XCTAssertEqual failed - stale control must not change B\n"
                   "Test Suite 'CallControlDispatchTests' failed at test-time\n"
                   "Executed 7 tests, with 6 failures (0 unexpected)\n")
        self.assertTrue(behavioral_red(fixture, 1))
        self.assertFalse(behavioral_red(fixture, 0))

    def test_compilation_and_missing_api_are_not_behavioral_red(self):
        self.assertFalse(behavioral_red("error: value of type CallController has no member end\nerror: fatalError", 1))
        self.assertFalse(behavioral_red("Test Suite 'CallControlDispatchTests' failed\nExecuted 0 tests, with 0 failures", 1))

    def test_crash_or_unexpected_error_is_not_expected_red(self):
        fixture = ("XCTAssertEqual failed - stale control must not change B\n"
                   "Test Suite 'CallControlDispatchTests' failed\n"
                   "Executed 7 tests, with 6 failures (0 unexpected)\n")
        self.assertFalse(behavioral_red(fixture + "Fatal error: owner precondition", 1))
        self.assertFalse(behavioral_red(fixture + "Exited with unexpected signal code 4", 1))
        self.assertFalse(behavioral_red(fixture.replace('(0 unexpected)', '(1 unexpected)'), 1))

    def test_an_unrelated_assertion_failure_is_not_the_requested_red(self):
        fixture = "Test Suite 'CallControlDispatchTests' failed\nExecuted 7 tests, with 6 failures"
        self.assertFalse(behavioral_red(fixture, 1))


if __name__ == '__main__':
    unittest.main()
