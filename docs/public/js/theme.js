// =============================================================================
// Theme Toggle - Tanuki Theme (タヌキ)
// Nintendo-inspired whimsical interactions
// =============================================================================

(function() {
  'use strict';

  const STORAGE_KEY = 'tanuki-theme';
  const THEMES = ['light', 'dark', 'auto'];

  // Get stored theme or default to auto
  function getStoredTheme() {
    try {
      return localStorage.getItem(STORAGE_KEY) || 'auto';
    } catch (e) {
      return 'auto';
    }
  }

  // Get effective theme (resolves 'auto' to actual theme)
  function getEffectiveTheme(stored) {
    if (stored === 'auto') {
      return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    }
    return stored;
  }

  // Apply theme to document
  function applyTheme(theme) {
    const effective = getEffectiveTheme(theme);
    document.documentElement.setAttribute('data-theme', effective);
    document.documentElement.setAttribute('data-theme-setting', theme);
  }

  // Save theme preference
  function saveTheme(theme) {
    try {
      localStorage.setItem(STORAGE_KEY, theme);
    } catch (e) {
      // Storage not available
    }
  }

  // Cycle through themes
  function cycleTheme() {
    const current = getStoredTheme();
    const currentIndex = THEMES.indexOf(current);
    const nextIndex = (currentIndex + 1) % THEMES.length;
    return THEMES[nextIndex];
  }

  // Create sparkle effect
  function createSparkles(button) {
    const rect = button.getBoundingClientRect();
    const centerX = rect.left + rect.width / 2;
    const centerY = rect.top + rect.height / 2;

    for (let i = 0; i < 6; i++) {
      const sparkle = document.createElement('div');
      sparkle.className = 'theme-sparkle';

      const angle = (i / 6) * Math.PI * 2;
      const distance = 30 + Math.random() * 20;
      const x = centerX + Math.cos(angle) * distance;
      const y = centerY + Math.sin(angle) * distance;

      sparkle.style.cssText = `
        position: fixed;
        left: ${x}px;
        top: ${y}px;
        width: 6px;
        height: 6px;
        background: var(--ctp-yellow);
        border-radius: 50%;
        pointer-events: none;
        z-index: 10000;
        animation: sparkle-fly 0.6s ease-out forwards;
      `;

      document.body.appendChild(sparkle);

      setTimeout(() => sparkle.remove(), 600);
    }
  }

  // Add sparkle animation
  function addSparkleStyles() {
    if (document.getElementById('tanuki-sparkle-styles')) return;

    const style = document.createElement('style');
    style.id = 'tanuki-sparkle-styles';
    style.textContent = `
      @keyframes sparkle-fly {
        0% {
          transform: scale(1);
          opacity: 1;
        }
        100% {
          transform: scale(0) translateY(-20px);
          opacity: 0;
        }
      }
    `;
    document.head.appendChild(style);
  }

  // Initialize theme toggle
  function initThemeToggle() {
    addSparkleStyles();

    // Apply initial theme immediately
    const stored = getStoredTheme();
    applyTheme(stored);

    // Set up toggle buttons
    document.querySelectorAll('.theme-toggle').forEach(button => {
      button.addEventListener('click', (e) => {
        e.preventDefault();

        // Cycle to next theme
        const newTheme = cycleTheme();
        saveTheme(newTheme);
        applyTheme(newTheme);

        // Add animation class
        button.classList.add('animating');
        setTimeout(() => button.classList.remove('animating'), 500);

        // Create sparkles for fun
        createSparkles(button);

        // Announce to screen readers
        const effective = getEffectiveTheme(newTheme);
        const announcement = `Theme changed to ${newTheme === 'auto' ? 'auto (' + effective + ')' : effective}`;
        announceToScreenReader(announcement);
      });
    });

    // Listen for system theme changes
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
      const stored = getStoredTheme();
      if (stored === 'auto') {
        applyTheme('auto');
      }
    });
  }

  // Screen reader announcement
  function announceToScreenReader(message) {
    const announcement = document.createElement('div');
    announcement.setAttribute('role', 'status');
    announcement.setAttribute('aria-live', 'polite');
    announcement.className = 'sr-only';
    announcement.textContent = message;
    document.body.appendChild(announcement);
    setTimeout(() => announcement.remove(), 1000);
  }

  // Initialize when DOM is ready
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initThemeToggle);
  } else {
    initThemeToggle();
  }

  // Apply theme immediately (before DOM ready) to prevent flash
  applyTheme(getStoredTheme());
})();
