# frozen_string_literal: true

require_relative "helper"

# Seam: Tasks::Player.system_prompt with prompt_override + user_prompts_dir.
# Spec: CONTEXT.md — Bakery visit recipe (navigate → shop list; explore only on navigate fail).
class TestBakeryVisitPrompt < Minitest::Test
  USER_PROMPTS = File.expand_path("../../../.boukensha/prompts", __dir__)

  def test_player_override_includes_bakery_visit_recipe
    text = Boukensha::Tasks::Player.system_prompt(
      { "prompt_override" => { "system" => true } },
      user_prompts_dir: USER_PROMPTS
    )

    assert text, "expected player system override under #{USER_PROMPTS}"
    assert_match(/### Bakery visit \(menu\)/, text)
    assert_match(/Prefer `navigate`/, text)
    assert_match(/provisional hop/, text)
    assert_match(/`shop` with action `list`/, text)
    assert_match(/look, examine, or inventory/, text)
    assert_match(/useful frontier/, text)
    assert_match(/then `explore` briefly/, text)
    assert_match(/Do \*\*not\*\* explore-first when navigate would work/, text)
  end

  def test_default_player_prompt_includes_bakery_visit_recipe
    text = Boukensha::Tasks::Player.system_prompt(
      {},
      default_prompts_dir: Boukensha::Config::PROMPTS_DIR
    )

    assert text, "expected default player system prompt"
    assert_match(/### Bakery visit \(menu\)/, text)
    assert_match(/`shop` with action `list`/, text)
    assert_match(/look, examine, or inventory/, text)
    assert_match(/useful frontier/, text)
    assert_match(/Do \*\*not\*\* explore-first when navigate would work/, text)
  end
end
