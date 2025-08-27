<template>
  <q-dialog>
    <q-card class="dialog">
      <q-btn
        icon="close"
        flat
        round
        dense
        v-close-popup
        class="dialog-close-btn"
      />

      <q-card-section class="q-pa-none q-ma-md" align="center">
        <!-- <q-icon name="mdi-alert-circle" color="primary" size="64px" /> -->
        <img src="~assets/flipper-busy.svg" class="q-ml-xs" />
        <div class="text-h6 q-my-sm">Kiisu is Busy</div>
        <div class="text-body q-my-sm">
          Exit the current app on Kiisu to use this feature
        </div>
      </q-card-section>

      <q-card-actions align="center">
        <slot />
      </q-card-actions>
    </q-card>
  </q-dialog>
</template>
