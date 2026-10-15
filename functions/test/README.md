Backend security regression tests

From the project root, with Node.js 22, Java 21 and Firebase CLI available:

```sh
npm --prefix functions ci
npm --prefix functions test
firebase emulators:exec --only firestore --project demo-lotto-fix --config functions/test/firebase.emulator.json 'node --test functions/test/backend.emulator.js'
```

The emulator suite loads the actual root `firestore.rules` through `initializeTestEnvironment`, replacing the initial deny-all rules. It requires `FIRESTORE_EMULATOR_HOST` and uses only the `demo-lotto-fix` project. Messaging is injected as an in-memory stub; tests do not send push notifications. The Admin SDK and client SDK both operate against the same local emulator so registration transactions and rule denials are checked together.

Deployment coordination

Deploy `registerUser` and the updated backend and Firestore rules before releasing the client that calls it. The new callable uses the verified custom-auth UID, not client identity fields. Its legacy Kakao migration retains source documents and copies only missing children, including their existing IDs; target records and deletion tombstones always win. `user_numbers` and `meta/userCount` are server-only allocation records. Client record writes require `updatedAt` to equal the server request time so a future client timestamp cannot poison incremental synchronization checkpoints.

Stricter rules intentionally reject old clients that write user identity fields, write a root FCM token or hard-delete synchronized records. Coordinate an app update with the rules rollout. Updated clients must register device tokens under `users/{uid}/devices/{deviceId}`. Private notifications have no legacy-token fallback, so existing installations receive private pushes after upgrading and registering an enabled device. Public `draw_result` topic notifications remain controlled by the client preference.

Manual and backfill saves are silent. Only the weekly scheduler requests a broadcast, and a transaction permits one notification attempt for a previously absent round newer than `meta/latest`. Processing and notification attempts are awaited. This suppresses duplicate sends on repeated calls; it does not promise exactly-once FCM delivery or automatic replay after a process crash. A repeated manual save can recompute statistics without notifying users.

Anonymous feedback retains the guest workflow with bounded text and identity fields. Volume throttling/App Check remains a separate rollout task. Existing production dependency versions were preserved; the added Firebase client/rules packages are test-only development dependencies.
