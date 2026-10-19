import Testing

@Test func shellSuiteSkipRequiresOnlyOneSkipLineAndExit77() {
    #expect(shellSuiteSkipped(77, "SKIP: unavailable loopback socket\n"))
    let failures: [(Int32, String)] = [
        (0, "SKIP: unavailable loopback socket\n"),
        (1, "SKIP: unavailable loopback socket\n"),
        (77, ""),
        (77, "SKIP: \n"),
        (77, "SKIP:   \n"),
        (77, "diagnostic containing SKIP: text\n"),
        (77, "FAIL: broken test\nSKIP: unavailable loopback socket\n"),
        (77, "pass: partial run\nSKIP: unavailable loopback socket\n"),
        (77, "SKIP: one\nSKIP: two\n"),
        (77, "SKIP: FAIL: broken preflight\n")
    ]
    for (status, output) in failures {
        #expect(!shellSuiteSkipped(status, output), "unexpected skip: \(output)")
    }
}
