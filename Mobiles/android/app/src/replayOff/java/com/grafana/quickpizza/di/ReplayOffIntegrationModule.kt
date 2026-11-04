package com.grafana.quickpizza.di

import com.grafana.quickpizza.core.o11y.NoOpSessionReplayIntegration
import com.grafana.quickpizza.core.o11y.SessionReplayIntegration
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object ReplayOffIntegrationModule {
    @Provides
    @Singleton
    fun provideSessionReplayIntegration(
        noOp: NoOpSessionReplayIntegration,
    ): SessionReplayIntegration = noOp
}
