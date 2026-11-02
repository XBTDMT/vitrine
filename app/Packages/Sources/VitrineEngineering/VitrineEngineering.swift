import Foundation

/// Engineering formats (S-22): the readers behind the cards for lockfiles (A-12), certificates and keys (T-10), API
/// specs (E-3), infrastructure files (E-4, T-8) and Apple development files (E-5). Pure parsers over bytes the
/// caller read: no network, no process, no file writes; they return Sendable summaries the previews draw.
/// roadmap: S-22
public enum VitrineEngineering {}
