package app.rxlab.rxcode.push

import kotlinx.serialization.Serializable

@Serializable
data class EncryptedAlert(
    val v: Int = 1,
    val from: String,
    val nonce: String,
    val ct: String,
)

@Serializable
data class AlertPlaintext(
    val title: String,
    val body: String,
    val sessionID: String? = null,
    val projectID: String? = null,
    val kind: String? = null,
)
