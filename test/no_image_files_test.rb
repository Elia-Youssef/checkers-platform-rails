require "test_helper"

# Everything the game draws is CSS and inline SVG written in code (TASK-BRIEF.md section 1.8,
# rubric item 49). That is a claim about the source tree, so it is checked against the source
# tree rather than against a rendered page: a stylesheet that quietly grew a url() to a sprite,
# or a partial that grew an image_tag, would still render and still pass every other test here.
#
# The only image files allowed anywhere are the three favicons the Rails generator put in
# public/ (icon.png, icon.svg and the apple-touch-icon, which is icon.png again). They are the
# browser tab, not the game.
#
# WHAT THIS TEST COVERS, exactly. It fails for an image file under app/ or public/ beyond those
# favicons, and for any reference to an image from a view, a helper, a stylesheet or a script.
# It does not read docs/, which holds the screenshots README.md shows on GitHub: those are
# documentation of the running application, nothing in the application references them, and the
# production image never carries them (.dockerignore excludes /docs). The exclusion is one
# directory in one test, the last one below; the other five are unchanged, so a screenshot
# copied into app/assets/images or named from a view still fails here.
class NoImageFilesTest < ActiveSupport::TestCase
  ROOT = Rails.root
  IMAGE_EXTENSIONS = %w[ png jpg jpeg gif webp bmp ico tiff avif svg ].freeze
  ALLOWED_IMAGE_FILES = [ "public/icon.png", "public/icon.svg" ].freeze

  # Where the game's own markup, styles and scripts live.
  SOURCE_GLOBS = [
    "app/views/**/*.erb",
    "app/helpers/**/*.rb",
    "app/assets/stylesheets/**/*.css",
    "app/javascript/**/*.js"
  ].freeze

  def source_files
    SOURCE_GLOBS.flat_map { |glob| Dir[ROOT.join(glob)] }.sort
  end

  def relative(path)
    Pathname.new(path).relative_path_from(ROOT).to_s
  end

  # A line's comment, so a sentence explaining that there is no url() here is not read as one.
  def code_of(line, path)
    if path.end_with?(".css")
      line.sub(%r{/\*.*}, "").sub(%r{^\s*\*.*}, "")
    elsif path.end_with?(".js")
      line.sub(%r{//.*}, "")
    else
      line.sub(/<%#.*/, "").sub(/^\s*#.*/, "")
    end
  end

  test "there is source to check" do
    assert_operator source_files.length, :>=, 25,
      "the globs matched #{source_files.length} files, so this test is checking nothing"
    assert_includes source_files.map { |path| relative(path) }, "app/assets/stylesheets/board.css"
    assert_includes source_files.map { |path| relative(path) }, "app/views/matches/_board.html.erb"
  end

  test "no view or helper reaches for an image" do
    offenders = []

    source_files.grep(/\.(erb|rb)\z/).each do |path|
      File.readlines(path).each_with_index do |line, index|
        code = code_of(line, path)
        next unless code.match?(/<img[\s>]/i) || code.match?(/\b(image_tag|image_path|image_url|asset_path\s*\(\s*["'][^"']+\.(?:#{IMAGE_EXTENSIONS.join("|")}))/i)

        offenders << "#{relative(path)}:#{index + 1}: #{line.strip}"
      end
    end

    assert_empty offenders, "the game uses no image file:\n#{offenders.join("\n")}"
  end

  test "no stylesheet uses url() at all" do
    offenders = []

    source_files.grep(/\.css\z/).each do |path|
      File.readlines(path).each_with_index do |line, index|
        next unless code_of(line, path).match?(/\burl\s*\(/i)

        offenders << "#{relative(path)}:#{index + 1}: #{line.strip}"
      end
    end

    assert_empty offenders, "a stylesheet reached outside itself with url():\n#{offenders.join("\n")}"
  end

  test "nothing in the game names an image file" do
    named = /["'][^"'\s]*\.(?:#{IMAGE_EXTENSIONS.join("|")})\b/i
    # The three <link rel> lines in the layout are the generated favicons, which are the browser
    # tab rather than the game. They are the one allowance, and they are matched exactly.
    favicon = %r{<link rel="(?:icon|apple-touch-icon)" href="/icon\.(?:png|svg)"}
    offenders = []

    source_files.each do |path|
      File.readlines(path).each_with_index do |line, index|
        code = code_of(line, path)
        next if code.match?(favicon)
        next unless code.match?(named)

        offenders << "#{relative(path)}:#{index + 1}: #{line.strip}"
      end
    end

    assert_empty offenders, "the game named an image file:\n#{offenders.join("\n")}"
  end

  test "app/assets/images holds nothing but .keep" do
    entries = Dir.children(ROOT.join("app/assets/images")).sort

    assert_equal [ ".keep" ], entries,
      "app/assets/images should hold only .keep, it holds #{entries.inspect}"
  end

  # docs/ is excluded here and only here: it holds the screenshots README.md shows on GitHub,
  # which document the application rather than belong to it. Nothing under app/, public/ or
  # config/ may reference them (the four tests above still read every view, helper, stylesheet
  # and script), and .dockerignore keeps the directory out of the production image. The rest of
  # the list is not this application at all: generated files, and gems a checkout may have
  # installed into vendor/bundle, which ship their own images and are ignored by git.
  SCANNED_OUT = %w[ /tmp/ /log/ /storage/ /node_modules/ /vendor/bundle/ /docs/ ].freeze

  test "the only image files in the tree are the generated favicons" do
    pattern = ROOT.join("**/*.{#{IMAGE_EXTENSIONS.join(",")}}").to_s
    found = Dir.glob(pattern, File::FNM_CASEFOLD)
      .reject { |path| SCANNED_OUT.any? { |part| path.include?(part) } }
      .map { |path| relative(path) }
      .sort

    assert_equal ALLOWED_IMAGE_FILES.sort, found,
      "unexpected image files under the Rails root: #{(found - ALLOWED_IMAGE_FILES).inspect}"
  end

  test "the board draws its pieces as inline SVG in a partial, not as a file" do
    piece = File.read(ROOT.join("app/views/matches/_piece.html.erb"))

    assert_match(/<svg/, piece, "the piece partial should draw an SVG in the page")
    assert_no_match(/<img|image_tag|xlink:href|\bsrc=/, piece)
  end
end
