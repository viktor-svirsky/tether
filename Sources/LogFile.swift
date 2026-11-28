import CoreTransferable
import UniformTypeIdentifiers

/// The log as a file to share, see `DebugLog`. It's written when the share sheet asks for it, so it
/// has the lines up to then.
struct LogFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in SentTransferredFile(try Model.writeLog()) }
    }
}
