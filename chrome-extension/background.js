// ツールバーのアイコンを押したらサイドパネルを開く。
chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch((error) => console.error(error));
