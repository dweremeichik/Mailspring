import {React} from 'nylas-exports';
import {ipcRenderer, remote, shell} from 'electron';
import {Notification} from 'nylas-component-kit';

export default class UpdateNotification extends React.Component {
  static displayName = 'UpdateNotification';

  constructor() {
    super();
    this.state = this.getStateFromStores();
  }

  componentDidMount() {
    this.disposable = NylasEnv.onUpdateAvailable(() => {
      this.setState(this.getStateFromStores())
    });
  }

  componentWillUnmount() {
    this.disposable.dispose();
  }

  getStateFromStores() {
    const updater = remote.getGlobal('application').autoUpdateManager;
    const updateAvailable = updater.getState() === 'update-available';
    const info = updateAvailable ? updater.getReleaseDetails() : {};
    return {
      updateAvailable,
      updateIsManual: info.releaseNotes === 'manual-download',
      version: info.releaseVersion,
    }
  }

  _onUpdate = () => {
    ipcRenderer.send('command', 'application:install-update')
  }

  _onViewChangelog = () => {
    shell.openExternal('https://github.com/Foundry376/Mailspring/releases/latest')
  }

  render() {
    const {updateAvailable, version, updateIsManual} = this.state;

    if (!updateAvailable) {
      return <span />
    }
    return (
      <Notification
        priority="4"
        title={`An update to Mailspring is available ${version ? `(${version})` : ''}`}
        subtitle="View changelog"
        subtitleAction={this._onViewChangelog}
        icon="volstead-upgrade.png"
        actions={[{
          label: updateIsManual ? 'Download Now' : 'Install Update',
          fn: this._onUpdate,
        }]}
      />
    )
  }
}
