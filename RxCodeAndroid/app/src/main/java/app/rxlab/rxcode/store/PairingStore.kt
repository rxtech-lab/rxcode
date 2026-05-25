package app.rxlab.rxcode.store

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import app.rxlab.rxcode.proto.RxJson
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.serialization.builtins.ListSerializer

private val Context.dataStore by preferencesDataStore(name = "rxcode.pairing")

/**
 * Plaintext storage for paired-desktop metadata + active selection. The mobile
 * key itself lives in [app.rxlab.rxcode.identity.DeviceIdentity] (Keystore-
 * encrypted prefs); this store only holds non-secret identifiers and labels.
 */
class PairingStore(private val context: Context) {
    private val pairedKey = stringPreferencesKey("pairedDesktops.json")
    private val activeKey = stringPreferencesKey("activeDesktopId")
    private val relayKey = stringPreferencesKey("relayUrl")

    val pairedDesktops: Flow<List<PairedDesktop>> =
        context.dataStore.data.map { decodeList(it[pairedKey]) }

    val activeDesktopId: Flow<String?> =
        context.dataStore.data.map { it[activeKey] }

    val relayUrl: Flow<String?> =
        context.dataStore.data.map { it[relayKey] }

    suspend fun upsert(desktop: PairedDesktop) {
        context.dataStore.edit { prefs ->
            val current = decodeList(prefs[pairedKey])
            val replaced = current
                .filterNot { it.id == desktop.id }
                .plus(desktop)
            prefs[pairedKey] = encodeList(replaced)
        }
    }

    suspend fun remove(id: String) {
        context.dataStore.edit { prefs ->
            val current = decodeList(prefs[pairedKey])
            prefs[pairedKey] = encodeList(current.filterNot { it.id == id })
            if (prefs[activeKey] == id) prefs.remove(activeKey)
        }
    }

    suspend fun setActive(id: String?) {
        context.dataStore.edit { prefs ->
            if (id == null) prefs.remove(activeKey) else prefs[activeKey] = id
        }
    }

    suspend fun setRelayUrl(url: String) {
        context.dataStore.edit { prefs -> prefs[relayKey] = url }
    }

    private val serializer = ListSerializer(PairedDesktop.serializer())

    private fun encodeList(list: List<PairedDesktop>): String =
        RxJson.encodeToString(serializer, list)

    private fun decodeList(raw: String?): List<PairedDesktop> {
        if (raw.isNullOrBlank()) return emptyList()
        return try {
            RxJson.decodeFromString(serializer, raw)
        } catch (_: Throwable) {
            emptyList()
        }
    }
}
