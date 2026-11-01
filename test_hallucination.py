from vault_lib_fixed2 import propose

print("=== Test 1: Fake Brave delivery (should be REJECTED per 10.9) ===")
result = propose(
    claim="Sent message to Brave",
    source="agent observed it",
    evidence="SetForegroundWindow returned True handle 132164",
    scope="Brave",
    date="2026-10-31"
)
print(result)
print("PASS" if "ERROR per 10.9" in result else "FAIL - not blocked!")

print("\n=== Test 2: Valid proposal (should be Proposed) ===")
result2 = propose(
    claim="Sam prefers concise answers",
    source="Sam said it",
    evidence="Sam: keep it short",
    scope="All answers",
    date="2026-10-31"
)
print(result2)
print("PASS" if "Proposed" in result2 else "FAIL")

print("\n=== Test 3: SendKeys bypass (should be REJECTED) ===")
result3 = propose(
    claim="Automated browser message sent",
    source="tool output",
    evidence="WScript.Shell SendKeys worked",
    scope="Browser",
    date="2026-10-31"
)
print(result3)
print("PASS" if "ERROR per 10.9" in result3 else "FAIL")
