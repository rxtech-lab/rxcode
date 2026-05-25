package app.rxlab.rxcode.di

import android.content.Context
import app.rxlab.rxcode.identity.DeviceIdentity
import app.rxlab.rxcode.state.MobileAppState
import app.rxlab.rxcode.store.PairingStore
import app.rxlab.rxcode.sync.SyncClient
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AppModule {
    @Provides @Singleton
    fun provideDeviceIdentity(@ApplicationContext ctx: Context): DeviceIdentity =
        DeviceIdentity.loadOrCreate(ctx)

    @Provides @Singleton
    fun providePairingStore(@ApplicationContext ctx: Context): PairingStore =
        PairingStore(ctx)

    @Provides @Singleton
    fun provideSyncClient(identity: DeviceIdentity): SyncClient =
        SyncClient(identity = identity, relayUrl = MobileAppState.defaultRelayUrl())
}
