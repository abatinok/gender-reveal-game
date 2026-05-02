-- ============================================================
-- Multi-Market Prediction Schema
-- Fully idempotent: safe to run multiple times
-- ============================================================

-- ------------------------------------------------------------
-- 1. MARKETS TABLE
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.markets (
  id           SERIAL PRIMARY KEY,
  slug         TEXT UNIQUE NOT NULL,
  title_he     TEXT NOT NULL,
  title_en     TEXT,
  market_type  TEXT NOT NULL DEFAULT 'binary', -- 'binary' or 'multiple'
  options      JSONB NOT NULL DEFAULT '[]',
  -- options format: [{"id": "boy", "label_he": "בן", "pool": 500}, ...]
  revealed     BOOLEAN NOT NULL DEFAULT FALSE,
  winner       TEXT,           -- winning option id
  actual_value TEXT,           -- display string of actual result
  reveal_order INT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ------------------------------------------------------------
-- 2. PREDICTIONS TABLE
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.predictions (
  id           SERIAL PRIMARY KEY,
  user_id      TEXT NOT NULL,
  nickname     TEXT,
  market_slug  TEXT NOT NULL REFERENCES public.markets(slug),
  option_id    TEXT NOT NULL,
  shares       NUMERIC NOT NULL DEFAULT 0,
  amount       NUMERIC NOT NULL DEFAULT 100,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(user_id, market_slug, option_id)
);

-- ------------------------------------------------------------
-- 3. AMM FUNCTION
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.place_market_bet(
  p_market_slug TEXT,
  p_user_id     TEXT,
  p_nickname    TEXT,
  p_option_id   TEXT,
  p_amount      NUMERIC DEFAULT 25
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_market        public.markets%ROWTYPE;
  v_existing_pred public.predictions%ROWTYPE;
  v_options       JSONB;
  v_found         BOOLEAN := FALSE;
  v_chosen_pool   NUMERIC := 0;
  v_other_pool    NUMERIC := 0;
  v_k             NUMERIC;
  v_new_other     NUMERIC;
  v_new_chosen    NUMERIC;
  v_shares_out    NUMERIC;
  v_new_options   JSONB;
  v_i             INT;
  v_opt           JSONB;
  v_old_pool      NUMERIC;
  v_proportional  NUMERIC;
  v_total_spent   NUMERIC := 0;
  v_balance       NUMERIC := 0;
  v_result        JSONB;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(p_user_id), hashtext('place_market_bet'));

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Bet amount must be positive';
  END IF;

  -- 1. Lock market row
  SELECT * INTO v_market
  FROM public.markets
  WHERE slug = p_market_slug
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Market not found: %', p_market_slug;
  END IF;

  -- 2. Validate: not revealed
  IF v_market.revealed THEN
    RAISE EXCEPTION 'Market is already revealed: %', p_market_slug;
  END IF;

  -- 3. Ignore duplicate bets on the same option before mutating market odds.
  SELECT * INTO v_existing_pred
  FROM public.predictions
  WHERE user_id = p_user_id
    AND market_slug = p_market_slug
    AND option_id = p_option_id
  FOR UPDATE;

  IF FOUND THEN
    SELECT row_to_json(m)::JSONB INTO v_result
    FROM public.markets m
    WHERE slug = p_market_slug;

    RETURN v_result;
  END IF;

  -- 4. Enforce bankroll.
  SELECT COALESCE(SUM(amount), 0) INTO v_total_spent
  FROM public.predictions
  WHERE user_id = p_user_id;

  v_balance := 1000 - v_total_spent;

  IF v_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient balance: have %, need %', v_balance, p_amount;
  END IF;

  -- 5. Validate: option_id exists
  v_options := v_market.options;
  FOR v_i IN 0 .. jsonb_array_length(v_options) - 1 LOOP
    v_opt := v_options -> v_i;
    IF v_opt ->> 'id' = p_option_id THEN
      v_found := TRUE;
      v_chosen_pool := (v_opt ->> 'pool')::NUMERIC;
    ELSE
      v_other_pool := v_other_pool + (v_opt ->> 'pool')::NUMERIC;
    END IF;
  END LOOP;

  IF NOT v_found THEN
    RAISE EXCEPTION 'Option not found: % in market %', p_option_id, p_market_slug;
  END IF;

  -- 3. Constant-product AMM
  --    User bets p_amount on option X.
  --    Money goes into the "against" (other) pool, which lowers the chosen pool.
  --    chosen_pool * other_pool = k  (invariant)
  v_k         := v_chosen_pool * v_other_pool;
  v_new_other := v_other_pool + p_amount;
  -- guard against zero other_pool (single-option degenerate case)
  IF v_other_pool = 0 OR v_k = 0 THEN
    v_shares_out := p_amount;
    v_new_chosen := v_chosen_pool;
  ELSE
    v_new_chosen := v_k / v_new_other;
    v_shares_out := v_chosen_pool - v_new_chosen;
  END IF;

  -- 4. Rebuild options JSONB with updated pools
  v_new_options := '[]'::JSONB;
  FOR v_i IN 0 .. jsonb_array_length(v_options) - 1 LOOP
    v_opt := v_options -> v_i;
    IF v_opt ->> 'id' = p_option_id THEN
      -- chosen option: pool shrinks
      v_new_options := v_new_options || jsonb_build_array(
        v_opt || jsonb_build_object('pool', ROUND(v_new_chosen, 6))
      );
    ELSE
      -- other options: distribute p_amount proportionally to their current share
      v_old_pool := (v_opt ->> 'pool')::NUMERIC;
      IF v_other_pool > 0 THEN
        v_proportional := v_old_pool + p_amount * (v_old_pool / v_other_pool);
      ELSE
        v_proportional := v_old_pool + p_amount / (jsonb_array_length(v_options) - 1);
      END IF;
      v_new_options := v_new_options || jsonb_build_array(
        v_opt || jsonb_build_object('pool', ROUND(v_proportional, 6))
      );
    END IF;
  END LOOP;

  -- 5. Persist updated market options
  UPDATE public.markets
  SET options    = v_new_options,
      updated_at = NOW()
  WHERE slug = p_market_slug;

  -- 6. Insert prediction (one row per user/market/option — re-clicking same option is a no-op)
  INSERT INTO public.predictions (user_id, nickname, market_slug, option_id, shares, amount)
  VALUES (p_user_id, p_nickname, p_market_slug, p_option_id, ROUND(v_shares_out, 6), p_amount)
  ;

  -- 7. Return updated market
  SELECT row_to_json(m)::JSONB INTO v_result
  FROM public.markets m
  WHERE slug = p_market_slug;

  RETURN v_result;
END;
$$;

-- ------------------------------------------------------------
-- 3b. RESET MARKET FUNCTION
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reset_market(p_market_slug TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_market  public.markets%ROWTYPE;
  v_opts    JSONB := '[]'::JSONB;
  v_i       INT;
  v_result  JSONB;
BEGIN
  SELECT * INTO v_market FROM public.markets WHERE slug = p_market_slug FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Market not found: %', p_market_slug;
  END IF;

  FOR v_i IN 0 .. jsonb_array_length(v_market.options) - 1 LOOP
    v_opts := v_opts || jsonb_build_array(
      (v_market.options -> v_i) || jsonb_build_object('pool', 500)
    );
  END LOOP;

  UPDATE public.markets
  SET options = v_opts, revealed = FALSE, winner = NULL, actual_value = NULL, updated_at = NOW()
  WHERE slug = p_market_slug;

  DELETE FROM public.predictions WHERE market_slug = p_market_slug;

  SELECT row_to_json(m)::JSONB INTO v_result FROM public.markets m WHERE slug = p_market_slug;
  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.reset_market(TEXT) TO anon, authenticated;

-- ------------------------------------------------------------
-- 4. LEADERBOARD VIEW
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW public.leaderboard AS
SELECT
  p.user_id,
  p.nickname,
  COUNT(*) FILTER (WHERE m.revealed AND p.option_id = m.winner)  AS correct,
  COUNT(*) FILTER (WHERE m.revealed)                              AS total_revealed,
  COUNT(*)                                                        AS total_predictions,
  COALESCE(SUM(CASE WHEN m.revealed AND p.option_id = m.winner THEN p.shares ELSE 0 END), 0) AS winnings,
  -- balance only counts bets on revealed markets so it stays hidden until reveals happen
  1000 - COUNT(*) FILTER (WHERE m.revealed) * 100
    + COALESCE(SUM(CASE WHEN m.revealed AND p.option_id = m.winner THEN p.shares ELSE 0 END), 0)
    AS balance
FROM public.predictions p
JOIN public.markets m ON p.market_slug = m.slug
GROUP BY p.user_id, p.nickname
-- only appear on leaderboard once at least one of your predictions has been revealed
HAVING COUNT(*) FILTER (WHERE m.revealed) > 0
ORDER BY balance DESC, correct DESC;

-- ------------------------------------------------------------
-- 5. ROW-LEVEL SECURITY
-- ------------------------------------------------------------
ALTER TABLE public.markets     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.predictions ENABLE ROW LEVEL SECURITY;

-- Markets: everyone can read
DROP POLICY IF EXISTS "markets_read" ON public.markets;
CREATE POLICY "markets_read" ON public.markets
  FOR SELECT TO anon, authenticated USING (true);

-- Predictions: everyone can read (for leaderboard)
DROP POLICY IF EXISTS "predictions_read" ON public.predictions;
CREATE POLICY "predictions_read" ON public.predictions
  FOR SELECT TO anon, authenticated USING (true);

-- Insert/update on predictions is handled exclusively via the
-- SECURITY DEFINER RPC function place_market_bet.

-- Predictions: users can delete their own predictions (to undo a bet)
DROP POLICY IF EXISTS "predictions_delete" ON public.predictions;
CREATE POLICY "predictions_delete" ON public.predictions
  FOR DELETE TO anon, authenticated USING (true);

-- Markets: admin reveals via direct update (party app — passcode is UI-only gate)
DROP POLICY IF EXISTS "markets_update" ON public.markets;
CREATE POLICY "markets_update" ON public.markets
  FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

-- ------------------------------------------------------------
-- 6. REALTIME
-- ------------------------------------------------------------
ALTER TABLE public.markets     REPLICA IDENTITY FULL;
ALTER TABLE public.predictions REPLICA IDENTITY FULL;

DO $$
BEGIN
  -- markets
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename  = 'markets'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.markets;
  END IF;

  -- predictions
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename  = 'predictions'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.predictions;
  END IF;
END;
$$;

-- ------------------------------------------------------------
-- 7. GRANTS
-- ------------------------------------------------------------
GRANT SELECT, UPDATE ON public.markets     TO anon, authenticated;
GRANT SELECT          ON public.predictions TO anon, authenticated;
GRANT SELECT ON public.leaderboard TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.place_market_bet(TEXT, TEXT, TEXT, TEXT, NUMERIC)
  TO anon, authenticated;

-- ------------------------------------------------------------
-- 8. SEED DATA  (INSERT ... ON CONFLICT DO UPDATE)
-- ------------------------------------------------------------

-- 2. weight
INSERT INTO public.markets (slug, title_he, market_type, options, reveal_order)
VALUES (
  'weight',
  'משקל',
  'multiple',
  '[{"id":"lt3","label_he":"פחות מ-3 ק״ג","pool":500},{"id":"3to33","label_he":"3-3.3 ק״ג","pool":500},{"id":"33to36","label_he":"3.3-3.6 ק״ג","pool":500},{"id":"36to4","label_he":"3.6-4 ק״ג","pool":500},{"id":"gt4","label_he":"יותר מ-4 ק״ג","pool":500}]'::JSONB,
  2
)
ON CONFLICT (slug) DO UPDATE SET
  title_he     = EXCLUDED.title_he,
  market_type  = EXCLUDED.market_type,
  options      = EXCLUDED.options,
  reveal_order = EXCLUDED.reveal_order,
  updated_at   = NOW();

-- 3. eye-color
INSERT INTO public.markets (slug, title_he, market_type, options, reveal_order)
VALUES (
  'eye-color',
  'צבע עיניים',
  'multiple',
  '[{"id":"blue","label_he":"כחול","pool":500},{"id":"brown","label_he":"חום","pool":500},{"id":"green","label_he":"ירוק","pool":500},{"id":"gray","label_he":"אפור","pool":500}]'::JSONB,
  3
)
ON CONFLICT (slug) DO UPDATE SET
  title_he     = EXCLUDED.title_he,
  market_type  = EXCLUDED.market_type,
  options      = EXCLUDED.options,
  reveal_order = EXCLUDED.reveal_order,
  updated_at   = NOW();

-- 4. name
INSERT INTO public.markets (slug, title_he, market_type, options, reveal_order)
VALUES (
  'name',
  'שם',
  'multiple',
  '[{"id":"name1","label_he":"שם א׳","pool":500},{"id":"name2","label_he":"שם ב׳","pool":500},{"id":"name3","label_he":"שם ג׳","pool":500}]'::JSONB,
  4
)
ON CONFLICT (slug) DO UPDATE SET
  title_he     = EXCLUDED.title_he,
  market_type  = EXCLUDED.market_type,
  options      = EXCLUDED.options,
  reveal_order = EXCLUDED.reveal_order,
  updated_at   = NOW();

-- 5. birth-date
INSERT INTO public.markets (slug, title_he, market_type, options, reveal_order)
VALUES (
  'birth-date',
  'תאריך לידה',
  'multiple',
  '[{"id":"oct10-16","label_he":"10-16 אוקטובר","pool":500},{"id":"oct17-23","label_he":"17-23 אוקטובר","pool":500},{"id":"oct24-30","label_he":"24-30 אוקטובר","pool":500},{"id":"oct31-nov6","label_he":"31 אוקטובר - 6 נובמבר","pool":500},{"id":"nov7plus","label_he":"7 נובמבר ומעלה","pool":500}]'::JSONB,
  5
)
ON CONFLICT (slug) DO UPDATE SET
  title_he     = EXCLUDED.title_he,
  market_type  = EXCLUDED.market_type,
  options      = EXCLUDED.options,
  reveal_order = EXCLUDED.reveal_order,
  updated_at   = NOW();

-- 6. birth-time
INSERT INTO public.markets (slug, title_he, market_type, options, reveal_order)
VALUES (
  'birth-time',
  'שעת לידה',
  'multiple',
  '[{"id":"night","label_he":"לילה 00:00-06:00","pool":500},{"id":"morning","label_he":"בוקר 06:00-12:00","pool":500},{"id":"noon","label_he":"צהריים 12:00-18:00","pool":500},{"id":"evening","label_he":"ערב 18:00-24:00","pool":500}]'::JSONB,
  6
)
ON CONFLICT (slug) DO UPDATE SET
  title_he     = EXCLUDED.title_he,
  market_type  = EXCLUDED.market_type,
  options      = EXCLUDED.options,
  reveal_order = EXCLUDED.reveal_order,
  updated_at   = NOW();

-- 7. day-of-week
INSERT INTO public.markets (slug, title_he, market_type, options, reveal_order)
VALUES (
  'day-of-week',
  'יום בשבוע',
  'multiple',
  '[{"id":"sun","label_he":"ראשון","pool":500},{"id":"mon","label_he":"שני","pool":500},{"id":"tue","label_he":"שלישי","pool":500},{"id":"wed","label_he":"רביעי","pool":500},{"id":"thu","label_he":"חמישי","pool":500},{"id":"fri","label_he":"שישי","pool":500},{"id":"sat","label_he":"שבת","pool":500}]'::JSONB,
  7
)
ON CONFLICT (slug) DO UPDATE SET
  title_he     = EXCLUDED.title_he,
  market_type  = EXCLUDED.market_type,
  options      = EXCLUDED.options,
  reveal_order = EXCLUDED.reveal_order,
  updated_at   = NOW();

-- 8. hair-color
INSERT INTO public.markets (slug, title_he, market_type, options, reveal_order)
VALUES (
  'hair-color',
  'צבע שיער',
  'multiple',
  '[{"id":"black","label_he":"שחור","pool":500},{"id":"brown","label_he":"חום","pool":500},{"id":"blonde","label_he":"בלונד","pool":500},{"id":"red","label_he":"ג׳ינג׳י","pool":500},{"id":"bald","label_he":"קירח","pool":500}]'::JSONB,
  8
)
ON CONFLICT (slug) DO UPDATE SET
  title_he     = EXCLUDED.title_he,
  market_type  = EXCLUDED.market_type,
  options      = EXCLUDED.options,
  reveal_order = EXCLUDED.reveal_order,
  updated_at   = NOW();

-- 9. length
INSERT INTO public.markets (slug, title_he, market_type, options, reveal_order)
VALUES (
  'length',
  'אורך',
  'multiple',
  '[{"id":"lt49","label_he":"פחות מ-49 ס״מ","pool":500},{"id":"49to51","label_he":"49-51 ס״מ","pool":500},{"id":"51to53","label_he":"51-53 ס״מ","pool":500},{"id":"gt53","label_he":"יותר מ-53 ס״מ","pool":500}]'::JSONB,
  9
)
ON CONFLICT (slug) DO UPDATE SET
  title_he     = EXCLUDED.title_he,
  market_type  = EXCLUDED.market_type,
  options      = EXCLUDED.options,
  reveal_order = EXCLUDED.reveal_order,
  updated_at   = NOW();

-- 10. looks-like
INSERT INTO public.markets (slug, title_he, market_type, options, reveal_order)
VALUES (
  'looks-like',
  'דומה יותר ל...',
  'multiple',
  '[{"id":"mom","label_he":"ניץ","pool":500},{"id":"dad","label_he":"עומר","pool":500}]'::JSONB,
  13
)
ON CONFLICT (slug) DO UPDATE SET
  title_he     = EXCLUDED.title_he,
  market_type  = EXCLUDED.market_type,
  options      = EXCLUDED.options,
  reveal_order = EXCLUDED.reveal_order,
  updated_at   = NOW();

-- 14. first-cry
INSERT INTO public.markets (slug, title_he, market_type, options, reveal_order)
VALUES (
  'first-cry',
  'מי יבכה ראשון?',
  'multiple',
  '[{"id":"baby","label_he":"התינוק","pool":500},{"id":"mom","label_he":"ניץ","pool":500},{"id":"dad","label_he":"עומר","pool":500},{"id":"grandparents","label_he":"סבא/סבתא","pool":500}]'::JSONB,
  14
)
ON CONFLICT (slug) DO UPDATE SET
  title_he     = EXCLUDED.title_he,
  market_type  = EXCLUDED.market_type,
  options      = EXCLUDED.options,
  reveal_order = EXCLUDED.reveal_order,
  updated_at   = NOW();
