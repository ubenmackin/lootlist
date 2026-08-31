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
      const isOpen = navLinks.classList.toggle('active');
      mobileToggle.setAttribute('aria-expanded', String(isOpen));
    });

    // Close mobile menu on link click
    navLinks.querySelectorAll('a').forEach(link => {
      link.addEventListener('click', () => {
        navLinks.classList.remove('active');
        mobileToggle.setAttribute('aria-expanded', 'false');
      });
    });
  }

  // 3. Showcase Tab Filtering Data & Logic
  const showcaseData = {
    childHub: {
      title: "Child Hub — Balance, Buckets & Today's Chores",
      description: "The Hero's home base: balance card, three bucket tiles, weekly progress ring, today's chores, and the FIFO top goal with Log a Purchase always within reach. Earnings are allocated to buckets and goals — never shown as fantasy currency.",
      bullets: [
        "Balance card and Spend / Short Term Save / Long Term Save tiles update instantly via SwiftData cache",
        "Progress ring tracks weekly chore momentum; completions celebrate with haptics & celebration overlay",
        "Today's chores plus the oldest incomplete FIFO goal surface the next action; Log a Purchase CTA stays visible"
      ],
      image: "assets/screenshots/child_dashboard.png",
      alt: "Child Hub — balance card, bucket tiles, progress ring, today's chores, FIFO top goal, Log a Purchase"
    },
    goals: {
      title: "My Goals — Short Save & Long Save",
      description: "Goals live inside their bucket and fill FIFO: the oldest incomplete, non-archived goal fills first, overflow cascades to the next, and surplus stays unallocated in the bucket. Pacing badges and progress bars make momentum tangible.",
      bullets: [
        "Separate Short Save and Long Save sections with goal cards, pacing badges, and progress bars",
        "FIFO goal pacing — oldest incomplete goal fills first, overflow cascades to the next goal",
        "Surplus past all goals stays unallocated in the bucket; amounts rendered in region currency"
      ],
      image: "assets/screenshots/child_goals.png",
      alt: "My Goals — Short Save and Long Save sections, goal cards with pacing badge and progress bar"
    },
    treasury: {
      title: "Treasury — Buckets & Ledger",
      description: "Real currency, real ledger. Bucket balances and a chronological ledger of contributions, transfers, and adjustments — formatted in the device region currency via CurrencyFormatter.",
      bullets: [
        "Bucket balances with Spend / Short Term Save / Long Term Save attribution on every ledger entry",
        "Ledger entries carry deterministic IDs for idempotent contributions, transfers, and imports",
        "WeekMath half-open [start, end) ranges keep the allowance week consistent with the ledger timeline"
      ],
      image: "assets/screenshots/hero_treasury.png",
      alt: "Treasury — bucket balances and chronological ledger with region-currency formatting"
    },
    trophies: {
      title: "Trophy Room — Hall of Heroes",
      description: "Hall of Heroes mastery header with a two-column grid of earned vs locked achievements. Criteria are quest-count tiers plus goal-based milestones like First Goal Created and Goal Getter — no level or XP is rendered.",
      bullets: [
        "Two-column grid distinguishes earned achievements from locked ones; mastery header summarizes progress",
        "Unlocks from quest-count tiers plus goal-based milestones; requirement text computed at render time",
        "Streak badges and unlockable app icons celebrate consistency without levels or XP display"
      ],
      image: "assets/screenshots/hero_trophy_room.png",
      alt: "Trophy Room — Hall of Heroes mastery header, two-column grid of earned versus locked achievements"
    },
    guild: {
      title: "Family Dashboard — Guild Masters & Rangers",
      description: "The parent view for the whole family: member roster, pending verifications, and weekly allowance status — backed by the CloudKit Shared Database and explicit readWrite invites.",
      bullets: [
        "Member overview with role-aware actions; pending completions notify for Parent Verify flows",
        "Weekly allowance period status including .paid as the atomic skip-guard against double payout",
        "CloudKit Shared Database sync via CKSyncEngine with .none publicPermission and role-decoded invites"
      ],
      image: "assets/screenshots/parent_dashboard.png",
      alt: "Parent Family Dashboard — member roster, pending verifications, weekly allowance summary"
    },
    payouts: {
      title: "Payout History — Weekly Settlement",
      description: "Every allowance week is a payout-day-aware half-open [start, end) range owned by WeekMath. Period closure and allocation happen only in runPayout, with AllowancePeriod .paid preventing double settlement.",
      bullets: [
        "AllowancePeriod .paid is the atomic skip-guard — realTime policy settles completions immediately, closure only in runPayout",
        "Net earnings split by the child's current percentages into buckets, then FIFO into goals with overflow cascading",
        "Monthly interest and parent match apply when configured, with deterministic IDs and check-before-apply guards"
      ],
      image: "assets/screenshots/parent_payout_history.png",
      alt: "Payout History — allowance periods with .paid skip-guard and weekly settlement details"
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
      tabButtons.forEach(b => {
        b.classList.remove('active');
        b.setAttribute('aria-selected', 'false');
      });
      btn.classList.add('active');
      btn.setAttribute('aria-selected', 'true');

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
          li.textContent = bullet;
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
            const otherBtn = other.querySelector('.faq-question');
            if (otherBtn) otherBtn.setAttribute('aria-expanded', 'false');
            const otherAnswer = other.querySelector('.faq-answer');
            if (otherAnswer) otherAnswer.style.maxHeight = null;
          }
        });

        // Toggle current item
        if (isActive) {
          item.classList.remove('active');
          questionBtn.setAttribute('aria-expanded', 'false');
          answer.style.maxHeight = null;
        } else {
          item.classList.add('active');
          questionBtn.setAttribute('aria-expanded', 'true');
          answer.style.maxHeight = answer.scrollHeight + 'px';
        }
      });
    }
  });
});
