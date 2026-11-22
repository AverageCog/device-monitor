/// Package-wide constants. Deliberately not named `DMCore`: a type with the module's name would make
/// `DMCore.SomeType` unusable for telling a package type from a same-named one in the app.
public enum DMCoreInfo {
    /// Path of the invitation link a hub shows for the iOS app (`<origin>/mobile#join=<code>`).
    public static let invitationPath = "/mobile"
}
