import XCTest
@testable import VitrineText

/// Secrets masked in config files (S-5, code state 16). Every value here is invented and not a real credential.
/// roadmap: S-5
final class SecretMaskTests: XCTestCase {
    func testTheDesignsDotEnvKeepsWhatIsNotSecret() {
        let env = """
        # Harbor Notes local overrides
        APP_ENV=development
        PORT=5173
        DATABASE_URL=postgres://harbor:hunter2-not-real@localhost:5432/harbor
        STRIPE_SECRET_KEY=sk_test_00000000000000000000000000
        SYNC_ENDPOINT=sync.example.com/v2
        SENTRY_DSN=https://0000@o0.ingest.example.invalid/0
        LOG_LEVEL=debug
        """
        let r = SecretMask.mask(env)
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.text, """
        # Harbor Notes local overrides
        APP_ENV=development
        PORT=5173
        DATABASE_URL=postgres://harbor:\(SecretMask.bullets(16))@localhost:5432/harbor
        STRIPE_SECRET_KEY=\(SecretMask.bullets(35))
        SYNC_ENDPOINT=sync.example.com/v2
        SENTRY_DSN=\(SecretMask.bullets(38))
        LOG_LEVEL=debug
        """)
        XCTAssertFalse(r.text.contains("hunter2"))
    }

    func testQuotesExportCommentsAndKnownForms() {
        let r = SecretMask.mask("""
        export API_TOKEN="abc123def456" # rotate monthly
        password: 'pa55'
        UPLOAD_HELPER=ghp_000000000000000000000000000000000000
        EMPTY_SECRET=
        ; NOT_A_SECRET_COMMENT=shown
        """)
        XCTAssertEqual(r.count, 3)
        XCTAssertEqual(r.text, """
        export API_TOKEN="\(SecretMask.bullets(12))" # rotate monthly
        password: '\(SecretMask.bullets(4))'
        UPLOAD_HELPER=\(SecretMask.bullets(40))
        EMPTY_SECRET=
        ; NOT_A_SECRET_COMMENT=shown
        """)
    }
}
