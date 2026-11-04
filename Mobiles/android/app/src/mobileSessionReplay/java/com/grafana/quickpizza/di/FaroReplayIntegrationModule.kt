package com.grafana.quickpizza.di

import com.grafana.quickpizza.core.o11y.FaroSessionReplayIntegration
import com.grafana.quickpizza.core.o11y.SessionReplayIntegration
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object FaroReplayIntegrationModule {
    @Provides
    @Singleton
    fun provideSessionReplayIntegration(
        integration: FaroSessionReplayIntegration,
    ): SessionReplayIntegration = integration
}
