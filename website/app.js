/**
 * Loot List Showcase Website - Interactivity & Logic
 */

document.addEventListener('DOMContentLoaded', () => {
  // 1. Header scroll detection
  const header = document.querySelector('.site-header');
  window.addEventListener('scroll', () => {
    if (window.scrollY > 40) {
      header.classList.add('scrolled');
    } else {
      header.classList.remove('scrolled');
    }
  });

  // 2. Mobile Menu Toggle
  const mobileToggle = document.querySelector('.mobile-toggle');
  const navLinks = document.querySelector('.nav-links');

  if (mobileToggle && navLinks) {
    mobileToggle.addEventListener('click', () => {
      navLinks.classList.toggle('active');
    });

    // Close mobile menu on link click
    navLinks.querySelectorAll('a').forEach(link => {
      link.addEventListener('click', () => {
        navLinks.classList.remove('active');
      });
    });
  }

  // 3. Showcase Tab Filtering Data & Logic
  const showcaseData = {
    hero: {
      title: "Hero Quests & Slain Chores",
      description: "Kids earn Gold for every quest completed. Configurable approval modes allow auto-payouts or parent verification for high-reward quests.",
      bullets: [
        "Interactive daily quest board with progress bars",
        "Mark quests as Slain ⚔️ with satisfying haptics",
        "Combo streaks 🔥 double gold rewards for consistency"
      ],
      image: "assets/screenshots/hero_quests.png",
      alt: "Hero Quests Screen"
    },
    treasury: {
      title: "Scroll of Spending & Treasury",
      description: "A comprehensive family ledger. Keep track of earnings, manual spending entries, or directly integrate with Apple Card via FinanceKit.",
      bullets: [
        "Real-time wallet balance and transaction logs",
        "Automatic weekly Sunday Loot Day payouts",
        "Manual ledger entries or FinanceKit spending sync"
      ],
      image: "assets/screenshots/treasury.png",
      alt: "Treasury View"
    },
    trophies: {
      title: "Hall of Heroes & Trophies",
      description: "Turn effort into celebration. Heroes unlock achievements, collect badges, and show off their quest history in the Hall of Heroes.",
      bullets: [
        "Milestones & streak trophy unlocks 🏆",
        "Custom hero avatar presets & badges",
        "Encourages long-term financial responsibility"
      ],
      image: "assets/screenshots/trophy_room.png",
      alt: "Trophy Room View"
    },
    guildmaster: {
      title: "Guild Master Family Dashboard",
      description: "Parents have full visibility over family members, custom quest templates, pending verifications, and allowance rules.",
      bullets: [
        "iCloud Shared Database — real-time push sync across devices",
        "Custom parent verify or auto-approve settings",
        "Granular notification controls per family role"
      ],
      image: "assets/screenshots/parent_dashboard.png",
      alt: "Parent Guild Dashboard"
    }
  };

  const tabButtons = document.querySelectorAll('.tab-btn');
  const showcaseTitle = document.getElementById('showcase-title');
  const showcaseDesc = document.getElementById('showcase-desc');
  const showcaseBullets = document.getElementById('showcase-bullets');
  const showcaseImg = document.getElementById('showcase-img');

  tabButtons.forEach(btn => {
    btn.addEventListener('click', () => {
      const tabKey = btn.getAttribute('data-tab');
      if (!showcaseData[tabKey]) return;

      // Active state on buttons
      tabButtons.forEach(b => b.classList.remove('active'));
      btn.classList.add('active');

      // Update content
      const data = showcaseData[tabKey];
      if (showcaseTitle) showcaseTitle.textContent = data.title;
      if (showcaseDesc) showcaseDesc.textContent = data.description;
      if (showcaseImg) {
        showcaseImg.src = data.image;
        showcaseImg.alt = data.alt;
      }

      if (showcaseBullets) {
        showcaseBullets.innerHTML = '';
        data.bullets.forEach(bullet => {
          const li = document.createElement('li');
          const span = document.createElement('span');
          span.textContent = '\u2694\uFE0F';
          li.appendChild(span);
          li.appendChild(document.createTextNode(' ' + bullet));
          showcaseBullets.appendChild(li);
        });
      }
    });
  });

  // 4. FAQ Accordion Interaction
  const faqItems = document.querySelectorAll('.faq-item');

  faqItems.forEach(item => {
    const questionBtn = item.querySelector('.faq-question');
    const answer = item.querySelector('.faq-answer');

    if (questionBtn && answer) {
      questionBtn.addEventListener('click', () => {
        const isActive = item.classList.contains('active');

        // Close other items
        faqItems.forEach(other => {
          if (other !== item) {
            other.classList.remove('active');
            const otherAnswer = other.querySelector('.faq-answer');
            if (otherAnswer) otherAnswer.style.maxHeight = null;
          }
        });

        // Toggle current item
        if (isActive) {
          item.classList.remove('active');
          answer.style.maxHeight = null;
        } else {
          item.classList.add('active');
          answer.style.maxHeight = answer.scrollHeight + 'px';
        }
      });
    }
  });
});
