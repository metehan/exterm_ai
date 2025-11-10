//Panel System
class PanelManager {
  constructor() {
    this.panels = ['left', 'middle', 'right'];
    this.activePanel = 'middle';
    this.panelSizes = {
      left: 250,
      middle: 400,
      right: 400
    };
    this.minPanelSize = 200;
    this.maxPanelSize = 800;
    this.isResizing = false;
    this.resizeData = null;

    // Load saved panel sizes from localStorage
    this.loadPanelSizes();

    this.init();
  }

  loadPanelSizes() {
    try {
      const savedSizes = localStorage.getItem('panelSizes');
      if (savedSizes) {
        const parsedSizes = JSON.parse(savedSizes);
        // Merge with defaults to ensure all panels have sizes
        this.panelSizes = { ...this.panelSizes, ...parsedSizes };
        console.log('Loaded panel sizes:', this.panelSizes);
      }
    } catch (error) {
      console.warn('Failed to load panel sizes:', error);
    }
  }

  savePanelSizes() {
    try {
      localStorage.setItem('panelSizes', JSON.stringify(this.panelSizes));
      console.log('Saved panel sizes:', this.panelSizes);
    } catch (error) {
      console.warn('Failed to save panel sizes:', error);
    }
  }

  init() {
    this.setupEventListeners();
    this.setupActivityBar();
    this.setupResizeHandles();
    this.setupPanelToggling();

    // Show both middle and right panels by default (terminal and chat)
    this.showMultiplePanels(['middle', 'right']);
    this.updateLayout();
  }

  showMultiplePanels(panelNames) {
    // Update activity bar - set all specified panels as active
    document.querySelectorAll('.activity-item').forEach(item => {
      const panelName = item.dataset.panel;
      if (panelNames.includes(panelName)) {
        item.classList.add('active');
      } else {
        item.classList.remove('active');
      }
    });

    // Update panels - show all specified panels
    document.querySelectorAll('.panel').forEach(panel => {
      const panelId = panel.id.replace('-panel', '');
      if (panelNames.includes(panelId)) {
        panel.classList.add('active');
      } else {
        panel.classList.remove('active');
      }
    });

    // Set the first panel as the primary active panel
    this.activePanel = panelNames[0];
  }

  setupEventListeners() {
    // Window resize handling
    window.addEventListener('resize', () => {
      this.updateLayout();
    });
  }

  setupActivityBar() {
    const activityItems = document.querySelectorAll('.activity-item');
    activityItems.forEach(item => {
      item.addEventListener('click', (e) => {
        const panelName = item.dataset.panel;
        this.togglePanel(panelName);
      });
    });
  }

  setupResizeHandles() {
    const resizeHandles = document.querySelectorAll('.resize-handle');
    resizeHandles.forEach(handle => {
      handle.addEventListener('mousedown', (e) => {
        this.startResize(e, handle);
      });
    });

    document.addEventListener('mousemove', (e) => {
      if (this.isResizing) {
        this.handleResize(e);
      }
    });

    document.addEventListener('mouseup', () => {
      this.stopResize();
    });
  }

  setupPanelToggling() {
    // Double-click activity items to toggle panel visibility
    const activityItems = document.querySelectorAll('.activity-item');
    activityItems.forEach(item => {
      item.addEventListener('dblclick', (e) => {
        const panelName = item.dataset.panel;
        this.togglePanelVisibility(panelName);
      });
    });
  }

  togglePanel(panelName) {
    const panel = document.getElementById(`${panelName}-panel`);
    const activityItem = document.querySelector(`[data-panel="${panelName}"]`);
    const isVisible = panel.classList.contains('active');

    if (isVisible) {
      // Hide the panel
      panel.classList.remove('active');
      activityItem.classList.remove('active');
    } else {
      // Show the panel
      panel.classList.add('active');
      activityItem.classList.add('active');
      this.activePanel = panelName;
    }

    this.updateLayout();
  }

  showPanel(panelName) {
    // Update activity bar
    document.querySelectorAll('.activity-item').forEach(item => {
      item.classList.remove('active');
    });
    document.querySelector(`[data-panel="${panelName}"]`).classList.add('active');

    // Update panels
    document.querySelectorAll('.panel').forEach(panel => {
      panel.classList.remove('active');
    });
    document.getElementById(`${panelName}-panel`).classList.add('active');

    this.activePanel = panelName;
    this.updateLayout();
  }

  togglePanelVisibility(panelName) {
    const panel = document.getElementById(`${panelName}-panel`);
    const isVisible = panel.classList.contains('active');

    if (isVisible) {
      panel.classList.remove('active');
      this.activePanel = null;
    } else {
      this.showPanel(panelName);
    }

    this.updateLayout();
  }

  startResize(e, handle) {
    this.isResizing = true;

    // Get current panel sizes from actual DOM elements
    const leftPanel = document.getElementById('left-panel');
    const middlePanel = document.getElementById('middle-panel');
    const rightPanel = document.getElementById('right-panel');

    const currentSizes = {
      left: leftPanel.offsetWidth || this.panelSizes.left,
      middle: middlePanel.offsetWidth || this.panelSizes.middle,
      right: rightPanel.offsetWidth || this.panelSizes.right
    };

    this.resizeData = {
      handle: handle,
      resizeType: handle.dataset.resize,
      startX: e.clientX,
      startSizes: currentSizes
    };

    // Add resizing class to panels
    document.querySelectorAll('.panel').forEach(panel => {
      panel.classList.add('resizing');
    });

    document.body.classList.add('resizing');
    e.preventDefault();
  }

  handleResize(e) {
    if (!this.isResizing || !this.resizeData) return;

    const deltaX = e.clientX - this.resizeData.startX;
    const { resizeType } = this.resizeData;

    const leftPanel = document.getElementById('left-panel');
    const middlePanel = document.getElementById('middle-panel');
    const rightPanel = document.getElementById('right-panel');

    const availableWidth = window.innerWidth - 48; // Minus activity bar

    if (resizeType === 'left-middle') {
      // Resizing between left and middle
      const visiblePanels = [];
      if (leftPanel.classList.contains('active')) visiblePanels.push('left');
      if (middlePanel.classList.contains('active')) visiblePanels.push('middle');
      if (rightPanel.classList.contains('active')) visiblePanels.push('right');

      // Calculate new left width
      let newLeftWidth = Math.max(200, Math.min(600, this.resizeData.startSizes.left + deltaX));

      if (visiblePanels.includes('right')) {
        // Three panels: ensure right doesn't disappear
        const minRightWidth = 200;
        const maxLeftWidth = availableWidth - 200 - minRightWidth; // Leave space for middle and right
        newLeftWidth = Math.min(newLeftWidth, maxLeftWidth);

        const remainingWidth = availableWidth - newLeftWidth;
        const middleWidth = remainingWidth - this.panelSizes.right;

        // Ensure middle doesn't get too small
        if (middleWidth < 200) {
          const adjustedMiddleWidth = 200;
          const adjustedRightWidth = remainingWidth - adjustedMiddleWidth;
          if (adjustedRightWidth >= 200) {
            this.panelSizes.middle = adjustedMiddleWidth;
            this.panelSizes.right = adjustedRightWidth;
          } else {
            // Redistribute space equally between middle and right
            this.panelSizes.middle = remainingWidth / 2;
            this.panelSizes.right = remainingWidth / 2;
          }
        } else {
          this.panelSizes.middle = middleWidth;
        }
      } else {
        // Two panels: left and middle
        const middleWidth = availableWidth - newLeftWidth;
        this.panelSizes.middle = Math.max(200, middleWidth);
      }

      this.panelSizes.left = newLeftWidth;

      // Apply widths
      leftPanel.style.width = `${this.panelSizes.left}px`;
      leftPanel.style.flex = 'none';
      middlePanel.style.width = `${this.panelSizes.middle}px`;
      middlePanel.style.flex = 'none';
      if (visiblePanels.includes('right')) {
        rightPanel.style.width = `${this.panelSizes.right}px`;
        rightPanel.style.flex = 'none';
      }

    } else if (resizeType === 'middle-right') {
      // Resizing between middle and right
      const visiblePanels = [];
      if (leftPanel.classList.contains('active')) visiblePanels.push('left');
      if (middlePanel.classList.contains('active')) visiblePanels.push('middle');
      if (rightPanel.classList.contains('active')) visiblePanels.push('right');

      let leftWidth = visiblePanels.includes('left') ? this.panelSizes.left : 0;
      let remainingWidth = availableWidth - leftWidth;

      // Calculate new middle width based on drag
      let middleWidth = Math.max(200, Math.min(remainingWidth - 200, this.resizeData.startSizes.middle + deltaX));
      let rightWidth = remainingWidth - middleWidth;

      // Ensure right width doesn't go below minimum
      if (rightWidth < 200) {
        rightWidth = 200;
        middleWidth = remainingWidth - rightWidth;
      }

      // Apply the new widths directly
      middlePanel.style.width = `${middleWidth}px`;
      middlePanel.style.flex = 'none';
      rightPanel.style.width = `${rightWidth}px`;
      rightPanel.style.flex = 'none';

      this.panelSizes.middle = middleWidth;
      this.panelSizes.right = rightWidth;
    }

    // Update resize handle positions
    this.updateResizeHandlePositions();
  }

  updateResizeHandlePositions() {
    const leftMiddleHandle = document.querySelector('[data-resize="left-middle"]');
    const middleRightHandle = document.querySelector('[data-resize="middle-right"]');

    const leftPanel = document.getElementById('left-panel');
    const middlePanel = document.getElementById('middle-panel');
    const rightPanel = document.getElementById('right-panel');

    const visiblePanels = [];
    if (leftPanel.classList.contains('active')) visiblePanels.push('left');
    if (middlePanel.classList.contains('active')) visiblePanels.push('middle');
    if (rightPanel.classList.contains('active')) visiblePanels.push('right');

    // Position left-middle handle (relative to main-content, not entire viewport)
    if (visiblePanels.includes('left') && (visiblePanels.includes('middle') || visiblePanels.includes('right'))) {
      leftMiddleHandle.style.left = `${this.panelSizes.left}px`; // No need to add activity bar width
    }

    // Position middle-right handle (relative to main-content, not entire viewport)
    if (visiblePanels.includes('middle') && visiblePanels.includes('right')) {
      let leftPosition = 0; // Start from 0 within main-content
      if (visiblePanels.includes('left')) {
        leftPosition += this.panelSizes.left;
      }
      leftPosition += this.panelSizes.middle;
      middleRightHandle.style.left = `${leftPosition}px`;
    }
  }

  stopResize() {
    this.isResizing = false;
    this.resizeData = null;

    // Remove resizing class from panels
    document.querySelectorAll('.panel').forEach(panel => {
      panel.classList.remove('resizing');
    });

    document.body.classList.remove('resizing');

    // Save the current panel sizes to localStorage
    this.savePanelSizes();
  }

  updateLayout() {
    const mainContent = document.querySelector('.main-content');
    const leftPanel = document.getElementById('left-panel');
    const middlePanel = document.getElementById('middle-panel');
    const rightPanel = document.getElementById('right-panel');

    // Calculate visible panels
    const visiblePanels = [];
    if (leftPanel.classList.contains('active')) visiblePanels.push('left');
    if (middlePanel.classList.contains('active')) visiblePanels.push('middle');
    if (rightPanel.classList.contains('active')) visiblePanels.push('right');

    // Calculate available width (full width minus activity bar)
    const availableWidth = window.innerWidth - 48; // 48px for activity bar

    if (visiblePanels.length === 1) {
      // Single panel takes full available width
      if (visiblePanels[0] === 'left') {
        leftPanel.style.width = '250px';
        this.panelSizes.left = 250;
      } else {
        const singlePanel = document.getElementById(`${visiblePanels[0]}-panel`);
        singlePanel.style.flex = '1';
        singlePanel.style.width = `${availableWidth}px`;
        this.panelSizes[visiblePanels[0]] = availableWidth;
      }
    } else if (visiblePanels.length === 2) {
      // Two panels split the available space
      if (visiblePanels.includes('left')) {
        leftPanel.style.width = `${this.panelSizes.left}px`;
        const otherPanel = visiblePanels.find(p => p !== 'left');
        const otherPanelElement = document.getElementById(`${otherPanel}-panel`);
        const remainingWidth = availableWidth - this.panelSizes.left;
        otherPanelElement.style.width = `${remainingWidth}px`;
        this.panelSizes[otherPanel] = remainingWidth;
      } else {
        // Middle and right split equally (or use saved sizes)
        middlePanel.style.width = `${this.panelSizes.middle}px`;
        rightPanel.style.width = `${this.panelSizes.right}px`;

        // Ensure they fill the available width
        const totalWidth = this.panelSizes.middle + this.panelSizes.right;
        if (Math.abs(totalWidth - availableWidth) > 10) {
          // Recalculate if sizes don't match available width
          this.panelSizes.middle = availableWidth / 2;
          this.panelSizes.right = availableWidth / 2;
          middlePanel.style.width = `${this.panelSizes.middle}px`;
          rightPanel.style.width = `${this.panelSizes.right}px`;
        }
      }
    } else if (visiblePanels.length === 3) {
      // Three panels: left fixed, middle and right split remaining
      // Ensure left doesn't take too much space
      const maxLeftWidth = Math.min(this.panelSizes.left, availableWidth * 0.4); // Max 40% of screen
      const remainingWidth = availableWidth - maxLeftWidth;

      // Ensure both middle and right have minimum widths
      const minWidthEach = 200;
      if (remainingWidth < minWidthEach * 2) {
        // Not enough space for all three panels with minimum widths
        // Reduce left width
        const adjustedLeftWidth = availableWidth - (minWidthEach * 2);
        this.panelSizes.left = Math.max(200, adjustedLeftWidth);
        this.panelSizes.middle = minWidthEach;
        this.panelSizes.right = minWidthEach;
      } else {
        // Distribute remaining space between middle and right
        const middleRightTotal = this.panelSizes.middle + this.panelSizes.right;
        if (Math.abs(middleRightTotal - remainingWidth) > 10) {
          // Recalculate proportionally
          const middleRatio = this.panelSizes.middle / middleRightTotal;
          const rightRatio = this.panelSizes.right / middleRightTotal;
          this.panelSizes.middle = remainingWidth * middleRatio;
          this.panelSizes.right = remainingWidth * rightRatio;
        }
        this.panelSizes.left = maxLeftWidth;
      }

      leftPanel.style.width = `${this.panelSizes.left}px`;
      middlePanel.style.width = `${this.panelSizes.middle}px`;
      rightPanel.style.width = `${this.panelSizes.right}px`;
    }

    // Update resize handles visibility and position
    this.updateResizeHandles(visiblePanels);
  }

  updateResizeHandles(visiblePanels = null) {
    if (!visiblePanels) {
      const leftPanel = document.getElementById('left-panel');
      const middlePanel = document.getElementById('middle-panel');
      const rightPanel = document.getElementById('right-panel');

      visiblePanels = [];
      if (leftPanel.classList.contains('active')) visiblePanels.push('left');
      if (middlePanel.classList.contains('active')) visiblePanels.push('middle');
      if (rightPanel.classList.contains('active')) visiblePanels.push('right');
    }

    const leftMiddleHandle = document.querySelector('[data-resize="left-middle"]');
    const middleRightHandle = document.querySelector('[data-resize="middle-right"]');

    // Hide all handles first
    leftMiddleHandle.style.display = 'none';
    middleRightHandle.style.display = 'none';

    // Show and position handles based on visible panels
    if (visiblePanels.includes('left') && (visiblePanels.includes('middle') || visiblePanels.includes('right'))) {
      leftMiddleHandle.style.display = 'block';
      leftMiddleHandle.style.left = `${this.panelSizes.left}px`; // Relative to main-content
    }

    if (visiblePanels.includes('middle') && visiblePanels.includes('right')) {
      middleRightHandle.style.display = 'block';
      let leftPosition = 0; // Start from 0 within main-content
      if (visiblePanels.includes('left')) {
        leftPosition += this.panelSizes.left;
      }
      leftPosition += this.panelSizes.middle;
      middleRightHandle.style.left = `${leftPosition}px`;
    }
  }
}

// Initialize panel manager when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
  window.panelManager = new PanelManager();
});

// Export for potential external use
if (typeof module !== 'undefined' && module.exports) {
  module.exports = PanelManager;
}
