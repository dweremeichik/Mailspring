import NylasStore from 'nylas-store';
import {remote} from 'electron';
import {makeRequest} from '../nylas-api-request';

const autoUpdater = remote.getGlobal('application').autoUpdateManager;
const preferredChannel = autoUpdater.preferredChannel;

class UpdateChannelStore extends NylasStore {
  constructor() {
    super();
    this._current = {name: 'Loading...'};
    this._available = [{name: 'Loading...'}];

    if (NylasEnv.isMainWindow()) {
      this.refreshChannel();
    }
  }

  current() {
    return this._current;
  }

  currentIsUnstable() {
    return this._current && this._current.name.toLowerCase() === 'beta';
  }

  available() {
    return this._available;
  }

  async refreshChannel() {
    // TODO BG
    try {
      const {current, available} = await makeRequest({
        server: 'identity',
        method: 'GET',
        path: `/api/update-channel`,
        qs: Object.assign({preferredChannel: preferredChannel}, autoUpdater.parameters()),
        json: true,
      });
      this._current = current || {name: "Channel API Not Available"};
      this._available = available || [];
      this.trigger();
    } catch (err) {
      // silent
    }
    return;
  }

  async setChannel(channelName) {
    try {
      const {current, available} = await makeRequest({
        server: 'identity',
        method: 'POST',
        path: `/api/update-channel`,
        qs: Object.assign({
          channel: channelName,
          preferredChannel: preferredChannel,
        }, autoUpdater.parameters()),
        json: true,
      });
      this._current = current || {name: "Channel API Not Available"};
      this._available = available || [];
      this.trigger();
    } catch (err) {
      NylasEnv.showErrorDialog(err.toString())
      this.trigger();
    }
    return null;
  }
}

export default new UpdateChannelStore();
