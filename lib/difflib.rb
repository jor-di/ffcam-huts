# Name similarity used to match hut names (refresh-coordinates, refresh-links): the
# Ratcliff/Obershelp score of Python's difflib (SequenceMatcher#ratio, get_close_matches),
# the algorithm the matches in hut_coordinates.json and hut_links.json were made with.
# Ported line by line so that scores and ties stay the same and a refresh doesn't move huts.
# ratio = 2 * matched characters / total length, matched characters being found by taking
# the longest common block, then recursing on both sides of it.

module Difflib
  class SequenceMatcher
    def initialize(a = "", b = "")
      set_seqs(a, b)
    end

    def set_seqs(a, b)
      set_seq1(a)
      set_seq2(b)
    end

    def set_seq1(a)
      @a = a.chars
      @matching_blocks = nil
    end

    def set_seq2(b)
      @b = b.chars
      @matching_blocks = nil
      chain_b
    end

    # b2j: element -> indices in b; with autojunk, elements of a long b (200+) that appear in
    # more than 1% of it are "popular" and left out (no junk function here).
    def chain_b
      @b2j = {}
      @b.each_with_index { |elt, i| (@b2j[elt] ||= []) << i }
      n = @b.size
      return unless n >= 200
      ntest = n / 100 + 1
      @b2j.reject! { |_, idxs| idxs.size > ntest }
    end

    # Longest matching block in a[alo...ahi] and b[blo...bhi] -> [i, j, size]
    def find_longest_match(alo, ahi, blo, bhi)
      besti, bestj, bestsize = alo, blo, 0
      j2len = {}
      (alo...ahi).each do |i|
        newj2len = {}
        (@b2j[@a[i]] || []).each do |j|
          next if j < blo
          break if j >= bhi
          k = newj2len[j] = j2len.fetch(j - 1, 0) + 1
          besti, bestj, bestsize = i - k + 1, j - k + 1, k if k > bestsize
        end
        j2len = newj2len
      end
      # extend with equal (popular) elements on both sides
      while besti > alo && bestj > blo && @a[besti - 1] == @b[bestj - 1]
        besti, bestj, bestsize = besti - 1, bestj - 1, bestsize + 1
      end
      bestsize += 1 while besti + bestsize < ahi && bestj + bestsize < bhi && @a[besti + bestsize] == @b[bestj + bestsize]
      [besti, bestj, bestsize]
    end

    def matching_blocks
      @matching_blocks ||= begin
        queue = [[0, @a.size, 0, @b.size]]
        blocks = []
        until queue.empty?
          alo, ahi, blo, bhi = queue.pop
          i, j, k = x = find_longest_match(alo, ahi, blo, bhi)
          next if k.zero?
          blocks << x
          queue << [alo, i, blo, j] if alo < i && blo < j
          queue << [i + k, ahi, j + k, bhi] if i + k < ahi && j + k < bhi
        end
        blocks.sort
      end
    end

    def ratio
      matches = matching_blocks.sum { |_, _, size| size }
      length = @a.size + @b.size
      length.positive? ? 2.0 * matches / length : 1.0
    end
  end

  # Best "good enough" matches of word among possibilities, best first (score, then string).
  def self.get_close_matches(word, possibilities, n: 3, cutoff: 0.6)
    s = SequenceMatcher.new
    s.set_seq2(word)
    result = possibilities.filter_map do |x|
      s.set_seq1(x)
      score = s.ratio
      [score, x] if score >= cutoff
    end
    result.max(n).map(&:last)
  end
end
