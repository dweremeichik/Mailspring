import NylasStore from 'nylas-store';

import {
  FeatureUsageStore,
  SyncbackMetadataTask,
  Actions,
  DatabaseStore,
  Thread,
} from 'nylas-exports';

import {moveThreads, snoozedUntilMessage} from './snooze-utils'
import {PLUGIN_ID} from './snooze-constants';
import SnoozeActions from './snooze-actions';

class SnoozeStore extends NylasStore {
  activate() {
    this.unsubscribers = [
      SnoozeActions.snoozeThreads.listen(this._onSnoozeThreads),
      DatabaseStore.listen((change) => {
        if (change.type !== 'metadata-expiration' || change.objectClass !== Thread.name) {
          return;
        }
        const unsnooze = change.objects.filter((model) => {
          const metadata = model.metadataForPluginId(PLUGIN_ID);
          return metadata && metadata.expiration && metadata.expiration < new Date();
        });
        if (unsnooze.length > 0) {
          this._onUnsnoozeThreads(unsnooze);
        }
      }),
    ];
  }

  deactivate() {
    this.unsubscribers.forEach(unsub => unsub())
  }

  _recordSnoozeEvent(threads, snoozeDate, label) {
    try {
      const timeInSec = Math.round(((new Date(snoozeDate)).valueOf() - Date.now()) / 1000);
      Actions.recordUserEvent("Threads Snoozed", {
        timeInSec: timeInSec,
        timeInLog10Sec: Math.log10(timeInSec),
        label: label,
        numItems: threads.length,
      });
    } catch (e) {
      // Do nothing
    }
  }

  _onSnoozeThreads = async (threads, snoozeDate, label) => {
    const lexicon = {
      displayName: "Snooze",
      usedUpHeader: "All Snoozes used",
      iconUrl: "mailspring://thread-snooze/assets/ic-snooze-modal@2x.png",
    }

    try {
      // ensure the user is authorized to use this feature
      await FeatureUsageStore.asyncUseFeature('snooze', {lexicon});

      // log to analytics
      this._recordSnoozeEvent(threads, snoozeDate, label);

      // move the threads to the snoozed folder
      await moveThreads(threads, {
        snooze: true,
        description: snoozedUntilMessage(snoozeDate),
      })

      // attach metadata to the threads to unsnooze them later
      Actions.queueTasks(threads.map((model) =>
        new SyncbackMetadataTask({
          model,
          pluginId: PLUGIN_ID,
          value: {
            expiration: snoozeDate,
          },
        }))
      );
    } catch (error) {
      if (error instanceof FeatureUsageStore.NoProAccessError) {
        return;
      }
      moveThreads(threads, {snooze: false, description: 'Unsnoozed'});
      Actions.closePopover();
      NylasEnv.reportError(error);
      NylasEnv.showErrorDialog(`Sorry, we were unable to save your snooze settings. ${error.message}`);
    }
  };

  _onUnsnoozeThreads = (threads) => {
    // move the threads back to the inbox
    moveThreads(threads, {snooze: false, description: 'Unsnoozed'});

    // remove the expiration on the metadata. note this is super important,
    // otherwise we'll receive a notification from the sync worker over and
    // over again.
    Actions.queueTasks(threads.map((model) =>
      new SyncbackMetadataTask({
        model,
        pluginId: PLUGIN_ID,
        value: {
          expiration: null,
        },
      })
    ));
  }
}

export default new SnoozeStore();

