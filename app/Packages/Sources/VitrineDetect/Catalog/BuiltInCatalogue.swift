// VitrineDetect — the 84 built-in detectors of DETECTORS.md §4, in catalogue order.
// Every pattern is written from the vendor's public token format; hints are made-up shapes, never real tokens.

enum BuiltInCatalogue {
    static let all: [Detector] = ai + cloud + payments + scm + messaging + databases + tokens + config + personal + network

    private static func d(
        _ id: String, _ title: String, _ category: Detector.Category, hint: String, _ patterns: [PatternSpec],
        validator: Validator = .none, validatedPatternIndexes: [Int]? = nil, scope: Scope = .match, on: Bool = true, severity: Detector.Severity
    ) -> Detector {
        Detector(id: id, title: title, category: category, hint: hint, patterns: patterns, validator: validator,
                 validatedPatternIndexes: validatedPatternIndexes, scope: scope, enabledByDefault: on, severity: severity)
    }

    // MARK: §4.1 AI providers — all on, critical
    static let ai: [Detector] = [
        d("ai.anthropic.apikey", "Anthropic API key", .ai, hint: "sk-ant-api03-…", [.prefix("sk-ant-", n: 24)], severity: .critical),
        d("ai.openai.apikey", "OpenAI API key", .ai, hint: "sk-proj-…", [.regex(#"\bsk-(?!ant-|or-)(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{32,}\b"#)], severity: .critical),
        d("ai.openrouter.apikey", "OpenRouter API key", .ai, hint: "sk-or-v1-…", [.prefix("sk-or-v1-", n: 40)], severity: .critical),
        d("ai.google.apikey", "Google / Gemini API key", .ai, hint: "AIza…", [.regex(#"\bAIza[0-9A-Za-z_\-]{35}\b"#)], severity: .critical),
        d("ai.huggingface.token", "Hugging Face token", .ai, hint: "hf_…", [.prefix("hf_", n: 30)], severity: .critical),
        d("ai.groq.apikey", "Groq API key", .ai, hint: "gsk_…", [.regex(#"\bgsk_[A-Za-z0-9]{52}\b"#)], severity: .critical),
        d("ai.replicate.token", "Replicate API token", .ai, hint: "r8_…", [.regex(#"\br8_[A-Za-z0-9]{37}\b"#)], severity: .critical),
        d("ai.xai.apikey", "xAI API key", .ai, hint: "xai-…", [.regex(#"\bxai-(?:token-)?[A-Za-z0-9]{80}\b"#)], severity: .critical),
        d("ai.mistral.apikey", "Mistral API key", .ai, hint: "MISTRAL_API_KEY=…", [.regex(#"(?i)\bMISTRAL_API_KEY\s*[=:]\s*["']?(?<secret>[A-Za-z0-9]{32})"#)], severity: .critical),
        d("ai.cohere.apikey", "Cohere API key", .ai, hint: "COHERE_API_KEY=…", [.regex(#"(?i)\b(?:COHERE|CO)_API_KEY\s*[=:]\s*["']?(?<secret>[A-Za-z0-9]{40})"#)], severity: .critical),
        d("ai.perplexity.apikey", "Perplexity API key", .ai, hint: "pplx-…", [.prefix("pplx-", n: 40)], severity: .critical),
        d("ai.deepseek.apikey", "DeepSeek API key", .ai, hint: "DEEPSEEK_API_KEY=sk-…", [.regex(#"(?i)\bDEEPSEEK_API_KEY\s*[=:]\s*["']?(?<secret>sk-[a-f0-9]{32})"#)], severity: .critical),
    ]

    // MARK: §4.2 Cloud
    static let cloud: [Detector] = [
        d("cloud.aws.accesskeyid", "AWS access key ID", .cloud, hint: "AKIA…", [.regex(#"\b(?:AKIA|ASIA|ABIA|ACCA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|ASCA)[A-Z0-9]{16}\b"#)], validator: .awsKeyIdPrefix, severity: .high),
        d("cloud.aws.secretkey", "AWS secret access key", .cloud, hint: "aws_secret_access_key = …", [
            .regex(#"(?i)\baws[_\-]?secret[_\-]?access[_\-]?key\b.{0,8}?[=:]\s*["']?(?<secret>[A-Za-z0-9/+=]{40})\b"#),
            .regex(#"(?i)\baws.{0,20}?secret.{0,20}?[=:]\s*["']?(?<secret>[A-Za-z0-9/+=]{40})\b"#),
        ], validator: .entropy(min: 3.5), severity: .critical),
        d("cloud.aws.sessiontoken", "AWS session token", .cloud, hint: "aws_session_token = …", [.regex(#"(?i)\baws[_\-]?session[_\-]?token\b.{0,8}?[=:]\s*["']?(?<secret>[A-Za-z0-9/+=]{100,})"#)], severity: .high),
        d("cloud.gcp.serviceaccount", "GCP service-account key file", .cloud, hint: "\"private_key_id\": \"…\"", [
            .regex(#""private_key_id"\s*:\s*"(?<secret>[a-f0-9]{40})""#),
            .regex(#""client_secret"\s*:\s*"(?<secret>GOCSPX-[A-Za-z0-9_\-]{28})""#),
        ], severity: .critical),
        d("cloud.gcp.oauthrefresh", "Google OAuth refresh token", .cloud, hint: "1//0…", [.regex(#"\b1//0[A-Za-z0-9_\-]{40,}\b"#)], severity: .high),
        d("cloud.azure.storagekey", "Azure storage account key / SAS", .cloud, hint: "AccountKey=…", [
            .regex(#"(?i)AccountKey=(?<secret>[A-Za-z0-9+/=]{86,88})"#),
            .regex(#"(?i)SharedAccessSignature=(?<secret>[^;\s]{20,})"#),
            .regex(#"(?i)[?&]sig=(?<secret>[A-Za-z0-9%+/=]{43,})"#),
        ], severity: .critical),
        d("cloud.azure.clientsecret", "Azure AD app client secret", .cloud, hint: "AZURE_CLIENT_SECRET=…", [.regex(#"(?i)\b(?:AZURE_)?CLIENT_SECRET\s*[=:]\s*["']?(?<secret>[A-Za-z0-9~._\-]{34,40})"#)], validator: .entropy(min: 3.5), severity: .critical),
        d("cloud.cloudflare.apitoken", "Cloudflare API token", .cloud, hint: "CLOUDFLARE_API_TOKEN=…", [
            .regex(#"(?i)\b(?:CF|CLOUDFLARE)_API_TOKEN\s*[=:]\s*["']?(?<secret>[A-Za-z0-9_\-]{40})"#),
            .regex(#"(?i)Authorization:\s*Bearer\s+(?<secret>[A-Za-z0-9_\-]{40})\b(?=.*cloudflare)"#),
        ], severity: .critical),
        d("cloud.digitalocean.token", "DigitalOcean token", .cloud, hint: "dop_v1_…", [
            .regex(#"\bdop_v1_[a-f0-9]{64}\b"#), .regex(#"\bdoo_v1_[a-f0-9]{64}\b"#), .regex(#"\bdor_v1_[a-f0-9]{64}\b"#),
        ], severity: .critical),
        d("cloud.heroku.apikey", "Heroku API key", .cloud, hint: "HEROKU_API_KEY=…", [.regex(#"(?i)\bHEROKU_API_KEY\s*[=:]\s*["']?(?<secret>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"#)], severity: .high),
        d("cloud.vercel.token", "Vercel token", .cloud, hint: "vercel_…", [.prefix("vercel_", n: 24)], severity: .critical),
        d("cloud.supabase.key", "Supabase keys", .cloud, hint: "sbp_… / sb_secret_…", [
            .prefix("sbp_", n: 40),
            .regex(#"\bsb_(?:secret|publishable)_[A-Za-z0-9_\-]{20,}\b"#),
            .regex(#"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b(?=.*(?:service_role|supabase))"#),
        ], validator: .jwt, validatedPatternIndexes: [2], severity: .critical),
        d("cloud.firebase.key", "Firebase / FCM server key", .cloud, hint: "AAAA…:…", [.regex(#"\bAAAA[A-Za-z0-9_\-]{7}:[A-Za-z0-9_\-]{140}\b"#)], severity: .high),
    ]

    // MARK: §4.3 Payments — on, critical (publishable off, low)
    static let payments: [Detector] = [
        d("payments.stripe.secretkey", "Stripe secret / restricted key", .payments, hint: "sk_live_…", [.regex(#"\b(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{24,}\b"#)], severity: .critical),
        d("payments.stripe.webhooksecret", "Stripe webhook signing secret", .payments, hint: "whsec_…", [.regex(#"\bwhsec_[A-Za-z0-9]{32,}\b"#)], severity: .critical),
        d("payments.stripe.publishable", "Stripe publishable key", .payments, hint: "pk_live_…", [.regex(#"\bpk_(?:live|test)_[A-Za-z0-9]{24,}\b"#)], on: false, severity: .low),
        d("payments.paypal.clientsecret", "PayPal client secret", .payments, hint: "PAYPAL_CLIENT_SECRET=…", [.regex(#"(?i)\bPAYPAL_(?:CLIENT_)?SECRET\s*[=:]\s*["']?(?<secret>[A-Za-z0-9_\-]{60,90})"#)], validator: .entropy(min: 3.5), severity: .critical),
        d("payments.square.token", "Square access token", .payments, hint: "EAAA… / sq0atp-…", [
            .regex(#"\bEAAA[A-Za-z0-9_\-]{60}\b"#), .regex(#"\bsq0atp-[A-Za-z0-9_\-]{22}\b"#), .regex(#"\bsq0csp-[A-Za-z0-9_\-]{43}\b"#),
        ], severity: .critical),
        d("payments.shopify.token", "Shopify tokens", .payments, hint: "shpat_…", [.regex(#"\bshp(?:at|ca|pa|ss)_[a-fA-F0-9]{32}\b"#)], severity: .critical),
    ]

    // MARK: §4.4 Source control & packages — on, critical
    static let scm: [Detector] = [
        d("scm.github.token", "GitHub token", .scm, hint: "ghp_… / github_pat_…", [
            .regex(#"\bgh[pousr]_[A-Za-z0-9]{36}\b"#), .regex(#"\bgithub_pat_[A-Za-z0-9]{22}_[A-Za-z0-9]{59}\b"#),
        ], validator: .githubChecksum, validatedPatternIndexes: [0], severity: .critical),
        d("scm.gitlab.token", "GitLab token", .scm, hint: "glpat-…", [
            .regex(#"\bglpat-[A-Za-z0-9_\-]{20,}\b"#), .regex(#"\bglptt-[a-f0-9]{40}\b"#),
            .regex(#"\bGR1348941[A-Za-z0-9_\-]{20,}\b"#), .regex(#"\bglrt-[A-Za-z0-9_\-]{20,}\b"#),
        ], severity: .critical),
        d("scm.npm.token", "npm token", .scm, hint: "npm_…", [.regex(#"\bnpm_[A-Za-z0-9]{36}\b"#)], severity: .critical),
        d("scm.pypi.token", "PyPI token", .scm, hint: "pypi-AgEIcHlwaS5vcmc…", [.regex(#"\bpypi-AgEIcHlwaS5vcmc[A-Za-z0-9_\-]{50,}\b"#)], severity: .critical),
        d("scm.rubygems.key", "RubyGems API key", .scm, hint: "rubygems_…", [.regex(#"\brubygems_[a-f0-9]{48}\b"#)], severity: .critical),
        d("scm.dockerhub.pat", "Docker Hub PAT", .scm, hint: "dckr_pat_…", [.regex(#"\bdckr_pat_[A-Za-z0-9_\-]{27,}\b"#)], severity: .critical),
        d("scm.postman.key", "Postman API key", .scm, hint: "PMAK-…-…", [.regex(#"\bPMAK-[a-f0-9]{24}-[a-f0-9]{34}\b"#)], severity: .critical),
        d("scm.linear.key", "Linear API key", .scm, hint: "lin_api_…", [.regex(#"\blin_api_[A-Za-z0-9]{40}\b"#)], severity: .critical),
        d("scm.notion.token", "Notion integration token", .scm, hint: "ntn_… / secret_…", [.regex(#"\b(?:secret|ntn)_[A-Za-z0-9]{43,50}\b"#)], severity: .critical),
        d("scm.atlassian.token", "Atlassian API token", .scm, hint: "ATATT3…", [.regex(#"\bATATT3[A-Za-z0-9_\-=]{180,}\b"#)], severity: .critical),
    ]

    // MARK: §4.5 Messaging & email — on, critical
    static let messaging: [Detector] = [
        d("messaging.slack.token", "Slack token", .messaging, hint: "xoxb-…", [
            .regex(#"\bxox[abeprs]-[0-9]{10,13}-[0-9A-Za-z\-]{10,}\b"#), .regex(#"\bxapp-[0-9]-[A-Z0-9]{10,}-[0-9]{10,}-[a-f0-9]{60,}\b"#),
        ], severity: .critical),
        d("messaging.slack.webhook", "Slack incoming webhook", .messaging, hint: "https://hooks.slack.com/services/T…/B…/…", [.regex(#"https://hooks\.slack\.com/(?:services|workflows)/T[A-Z0-9]{8,}/B[A-Z0-9]{8,}/[A-Za-z0-9]{20,}"#)], severity: .critical),
        d("messaging.discord.token", "Discord bot token", .messaging, hint: "M….….…", [.regex(#"\b[MN][A-Za-z\d]{23,}\.[\w\-]{6}\.[\w\-]{27,}\b"#)], severity: .critical),
        d("messaging.discord.webhook", "Discord webhook", .messaging, hint: "https://discord.com/api/webhooks/…/…", [.regex(#"https://(?:ptb\.|canary\.)?discord(?:app)?\.com/api/webhooks/\d{17,20}/[A-Za-z0-9_\-]{60,}"#)], severity: .critical),
        d("messaging.telegram.bottoken", "Telegram bot token", .messaging, hint: "123456789:AA…", [.regex(#"\b\d{8,10}:AA[A-Za-z0-9_\-]{33}\b"#)], severity: .critical),
        d("messaging.sendgrid.apikey", "SendGrid API key", .messaging, hint: "SG.….…", [.regex(#"\bSG\.[A-Za-z0-9_\-]{22}\.[A-Za-z0-9_\-]{43}\b"#)], severity: .critical),
        d("messaging.twilio.credentials", "Twilio SID / API key / auth token", .messaging, hint: "AC… / SK…", [
            .regex(#"\b(?:AC|SK)[0-9a-fA-F]{32}\b"#), .regex(#"(?i)\bTWILIO_AUTH_TOKEN\s*[=:]\s*["']?(?<secret>[0-9a-f]{32})"#),
        ], severity: .critical),
        d("messaging.mailgun.apikey", "Mailgun API key", .messaging, hint: "key-…", [
            .regex(#"\bkey-[a-f0-9]{32}\b"#), .regex(#"\b[a-f0-9]{32}-[a-f0-9]{8}-[a-f0-9]{8}\b(?=.*mailgun)"#),
        ], severity: .critical),
        d("messaging.mailchimp.apikey", "Mailchimp API key", .messaging, hint: "…-us21", [.regex(#"\b[a-f0-9]{32}-us\d{1,2}\b"#)], severity: .critical),
        d("messaging.postmark.token", "Postmark server token", .messaging, hint: "POSTMARK_SERVER_TOKEN=…", [.regex(#"(?i)\bPOSTMARK_(?:SERVER_)?TOKEN\s*[=:]\s*["']?(?<secret>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"#)], severity: .critical),
    ]

    // MARK: §4.6 Databases — on, critical
    static let databases: [Detector] = [
        d("databases.url.credentials", "Connection string with password", .databases, hint: "postgres://user:…@host/db", [.regex(#"(?i)\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis|rediss|amqps?|mssql|sqlserver|oracle|clickhouse|cockroachdb|neo4j|ftp|sftp|smb):\/\/[^\s:@\/]+:(?<secret>[^\s@\/]+)@[^\s]+"#)], severity: .critical),
        d("databases.jdbc.password", "JDBC / ADO.NET password", .databases, hint: "jdbc:…?password=…", [
            .regex(#"(?i)jdbc:[a-z0-9:]+:\/\/\S*?[?&;](?:password|pwd)=(?<secret>[^&;\s]+)"#),
            .regex(#"(?i)\b(?:password|pwd)\s*=\s*(?<secret>[^;\s]+)\s*;"#),
        ], severity: .critical),
        d("databases.mongodb.atlas", "MongoDB Atlas URI", .databases, hint: "mongodb+srv://user:…@cluster0.abcde.mongodb.net", [.regex(#"mongodb\+srv:\/\/[^\s:@]+:(?<secret>[^\s@]+)@[a-z0-9\-]+\.[a-z0-9]+\.mongodb\.net"#)], severity: .critical),
        d("databases.planetscale.token", "PlanetScale token", .databases, hint: "pscale_tkn_…", [.regex(#"\bpscale_(?:tkn|pw|oauth)_[A-Za-z0-9_\-]{32,}\b"#)], severity: .critical),
    ]

    // MARK: §4.7 Tokens & private keys
    static let tokens: [Detector] = [
        // The dash run starts only at its first dash and is taken possessively, so a long run of dashes is searched once,
        // not once per dash (security scan 2026-10-28 F14 audit: quadratic before; RegexWorkTests).
        d("tokens.pem.privatekey", "Private key block (PEM/OpenSSH/PGP)", .tokens, hint: "-----BEGIN PRIVATE KEY-----", [.regex(#"(?<!-)-++\s*+BEGIN (?:[A-Z ]*PRIVATE KEY|PGP PRIVATE KEY BLOCK|OPENSSH PRIVATE KEY)\s*-+"#)],
          scope: .block(endMarkers: ["END", "PRIVATE KEY"]), severity: .critical),
        d("tokens.jwt.compact", "JSON Web Token", .tokens, hint: "eyJ….eyJ….…", [.regex(#"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b"#)], validator: .jwt, severity: .high),
        d("tokens.auth.header", "Bearer / API-key header", .tokens, hint: "Authorization: Bearer …", [
            .regex(#"(?i)\bAuthorization\s*:\s*(?:Bearer|Token|Basic)\s+(?<secret>[A-Za-z0-9._~+\/=\-]{16,})"#),
            .regex(#"(?i)\bx-api-key\s*:\s*(?<secret>\S{12,})"#),
            .regex(#"(?i)\b(?:api[-_]?key|apikey)\s*:\s*(?<secret>[A-Za-z0-9._~+\/=\-]{16,})"#),
        ], severity: .high),
        d("tokens.otp.uri", "2FA setup URI", .tokens, hint: "otpauth://totp/…?secret=…", [.regex(#"otpauth:\/\/(?:totp|hotp)\/[^\s?]+\?[^\s]*secret=(?<secret>[A-Z2-7]{16,})"#)], severity: .critical),
        d("tokens.ssh.publickey", "SSH public key", .tokens, hint: "ssh-ed25519 AAAA…", [.regex(#"\b(?:ssh-(?:rsa|ed25519|dss)|ecdsa-sha2-nistp\d{3}) AAAA[A-Za-z0-9+\/=]{40,}"#)], on: false, severity: .low),
        d("tokens.basicauth.url", "URL with embedded credentials (non-DB)", .tokens, hint: "https://user:…@host/", [.regex(#"(?i)\bhttps?:\/\/[^\s:@\/]+:(?<secret>[^\s@\/]+)@[^\s]+"#)], severity: .high),
        d("tokens.kubeconfig.token", "Kubernetes service-account token", .tokens, hint: "token: eyJ…", [.regex(#"(?i)^\s*token:\s*(?<secret>eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,})\s*$"#)], validator: .jwt, severity: .high),
        d("tokens.netrc.password", ".netrc password", .tokens, hint: "machine … login … password …", [
            .regex(#"(?i)\bmachine\s+\S+\s+login\s+\S+\s+password\s+(?<secret>\S+)"#), .regex(#"(?i)^\s*password\s+(?<secret>\S+)\s*$"#),
        ], severity: .high),
        d("tokens.sentry.dsn", "Sentry DSN", .tokens, hint: "https://…@o0.ingest.sentry.io/0", [.regex(#"https:\/\/(?<secret>[a-f0-9]{32})@[a-z0-9.\-]+\.ingest(?:\.[a-z]{2})?\.sentry\.io\/\d+"#)], severity: .medium),
        d("tokens.datadog.apikey", "Datadog API / app key", .tokens, hint: "DD_API_KEY=…", [.regex(#"(?i)\bDD_(?:API|APP)_KEY\s*[=:]\s*["']?(?<secret>[a-f0-9]{32,40})"#)], severity: .critical),
        d("tokens.newrelic.key", "New Relic key", .tokens, hint: "NRAK-…", [
            .regex(#"\bNRAK-[A-Z0-9]{27}\b"#), .regex(#"\bNRJS-[a-f0-9]{19}\b"#), .regex(#"\b[A-Za-z0-9]{40}NRAL\b"#),
        ], severity: .critical),
    ]

    // MARK: §4.8 Config files — on
    static let config: [Detector] = [
        // The key name is one token of [A-Za-z0-9_.-] holding a secret word, then `=` or `:` and the value. Linear time
        // (security scan 2026-10-28 F14): a match starts only where a token starts (the lookbehind), the secret word is
        // found by a lazy lookahead that cannot leave the token, and the token, spaces and quote are taken possessively,
        // so no two runs trade characters. The earlier form (`\b` run, word, run) backtracked in cubic time on a long
        // line of `pass.pass.…` with no `=` (RegexWorkTests).
        d("config.env.secret", "Secret in .env / config", .config, hint: "API_KEY=…", [.regex(##"(?i)(?<![A-Za-z0-9_.\-])(?=[A-Za-z0-9_.\-]*?(?:SECRET|TOKEN|PASSW(?:OR)?D|PASS|PWD|API[_\-]?KEY|ACCESS[_\-]?KEY|PRIVATE[_\-]?KEY|AUTH[_\-]?KEY|CLIENT[_\-]?SECRET|CREDENTIALS?|SIGNING[_\-]?KEY|ENCRYPTION[_\-]?KEY|[_.\-]KEY(?![A-Za-z0-9_.\-])))[A-Za-z0-9_.\-]++\s*+[=:]\s*+["']?+(?<secret>[^\s"'#]{8,})"##)], validator: .entropy(min: 3.0), severity: .critical),
        d("config.labelled.password", "Labelled password", .config, hint: "password: …", [.regex(#"(?i)\b(?:password|passwd|passcode|pwd|pin)\s*[:=]\s*["']?(?<secret>[^\s"';,]{4,})"#)], severity: .high),
        d("config.yaml.secret", "YAML/JSON secret fields", .config, hint: "api_key: …", [.regex(#"(?i)^\s*["']?(?:[A-Za-z0-9_\-]*(?:secret|token|password|api[_\-]?key|[_\-]key(?=["']?\s*:)))["']?\s*:\s*["']?(?<secret>[^\s"',]{8,})"#)], validator: .entropy(min: 3.0), severity: .high),
        d("config.cli.flag", "Secret passed as a CLI flag", .config, hint: "--password …", [.regex(#"(?i)--?(?:password|passwd|token|api[-_]?key|secret)(?:[= ])(?<secret>[^\s"']{6,})"#)], severity: .high),
        // G-16: a value labelled in plain words ("API key: …", "Key: …"). Last in the section on purpose: the most generic
        // label owns a merged finding least (§8), so a vendor or code-style detector on the same value keeps the label.
        // Pattern 0: digits only, ≥ 16 (above E.164's 15, so no phone number), never one repeated digit.
        // Pattern 1: anything else, ≥ 16, not a URL or path, behind the entropy validator (§5.3: digit + letter, placeholders).
        // Its host-and-path exclusion (`a.b/`, each dot between name characters) is written without a repeated group
        // inside a repeat, the shape RegexComplexity refuses (security scan 2026-10-28 F23); it reads the same text.
        d("config.labelled.secret", "Labelled secret", .config, hint: "API key: …", [
            .regex(BuiltInCatalogue.proseSecretLabel + #"(?<secret>(?!(?<rep>[0-9])\k<rep>+(?![0-9]))[0-9]{16,})(?=["'`]?[.,;:!?]?(?:\s|$))"#),
            .regex(BuiltInCatalogue.proseSecretLabel + #"(?<secret>(?![^\s"'`]*://)(?![~.]{0,2}/)(?![\w\-]+\.(?=[\w\-])(?:[\w\-]|\.(?=[\w\-]))*/)[^\s"'`]{15,}[^\s"'`.,;:!?])"#),
        ], validator: .entropy(min: 3.0), validatedPatternIndexes: [1], severity: .high),
    ]

    /// The plain-word secret labels of `config.labelled.secret` (G-16), case-insensitive, words joined by a space, `_` or
    /// `-`, then `:` or `=` and an optional opening quote. A bare `key` is not a label after `public`, `primary`, `foreign`,
    /// `partition`, `sort`, `composite` or `unique` (a public key, a database key); `\b` keeps `Monkey:` and `Keyboard:` out.
    static let proseSecretLabel = #"(?i)\b(?:(?:api|secret|access|private|licen[cs]e|auth)[ _\-]?key|(?:(?:access|auth|bearer)[ _\-]?)?token|(?:client[ _\-]?)?secret|(?<!\b(?:public|primary|foreign|partition|sort|composite|unique)[ _\-])key)\s*[:=]\s*["'`]?"#

    // MARK: §4.9 Personal info
    static let personal: [Detector] = [
        d("personal.card.pan", "Payment card number", .personal, hint: "4111 1111 1111 1111", [.regex(#"\b(?:\d[ \-]?){12,18}\d\b"#)], validator: .luhn, severity: .medium),
        d("personal.iban.account", "IBAN", .personal, hint: "DE89 3704 0044 0532 0130 00", [.regex(#"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?\b"#)], validator: .ibanMod97, severity: .medium),
        d("personal.ssn.us", "US Social Security number", .personal, hint: "123-45-6789", [.regex(#"\b(?!000|666|9\d\d)\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b"#)], on: false, severity: .low),
        d("personal.email.address", "Email address", .personal, hint: "name@example.com", [.regex(#"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,24}\b"#)], on: false, severity: .low),
        d("personal.phone.e164", "Phone number (international)", .personal, hint: "+44 20 7946 0000", [.regex(#"(?<![\w+])\+\d{1,3}(?:[ .\-]?\(?\d{1,4}\)?)?(?:[ .\-]?\d){6,12}\b"#)], validator: .phoneShape(minDigits: 8, maxDigits: 15), on: false, severity: .low),
        d("personal.phone.nanp", "Phone number (North America)", .personal, hint: "(212) 555-0199", [.regex(#"(?<!\d)(?:\+?1[ .\-]?)?(?:\([2-9]\d{2}\)[ .\-]?|\(?[2-9]\d{2}\)?[ .\-])\d{3}[ .\-]\d{4}\b"#)], on: false, severity: .low),
        d("personal.passport.mrz", "Passport MRZ line", .personal, hint: "P<UTOERIKSSON<<ANNA<MARIA<<<<<<<<<<<<<<<<<<<", [.regex(#"\bP<[A-Z]{3}[A-Z<]{39}(?![A-Z<])"#)], on: false, severity: .medium),
        d("personal.dob.labelled", "Date of birth (labelled)", .personal, hint: "DOB: 01/02/1990", [.regex(#"(?i)\b(?:DOB|date of birth|born)\s*[:=]?\s*(?<secret>\d{1,2}[\/.\-]\d{1,2}[\/.\-]\d{2,4}|\d{4}-\d{2}-\d{2})"#)], on: false, severity: .low),
    ]

    // MARK: §4.10 Network — all off, low
    static let network: [Detector] = [
        d("network.ip.v4", "IPv4 address", .network, hint: "192.0.2.10", [.regex(#"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#)], on: false, severity: .low),
        d("network.ip.v6", "IPv6 address", .network, hint: "2001:db8::1", [.regex(#"(?<![:\w])(?:[A-Fa-f0-9]{1,4}:){2,7}[A-Fa-f0-9]{1,4}(?![:\w])"#)], on: false, severity: .low),
        d("network.mac.address", "MAC address", .network, hint: "00:1A:2B:3C:4D:5E", [.regex(#"\b(?:[0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}\b"#)], on: false, severity: .low),
        d("network.hostname.internal", "Internal hostname", .network, hint: "db-01.internal", [.regex(#"\b[a-z0-9\-]+\.(?:internal|local|corp|lan|intranet)\b"#)], on: false, severity: .low),
        d("network.apple.serial", "Mac serial number (labelled)", .network, hint: "Serial Number: …", [.regex(#"(?i)\bserial(?: number)?\s*[:=]?\s*(?<secret>[A-Z0-9]{10,12})\b"#)], on: false, severity: .low),
    ]
}
