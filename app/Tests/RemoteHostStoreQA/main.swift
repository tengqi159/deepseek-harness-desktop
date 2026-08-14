import Foundation

@main
enum RemoteHostStoreQAMain {
    static func main() {
        RemoteHostStore.runLocalSecurityQA()
        print("REMOTE_HOST_STORE_QA_OK")
    }
}
