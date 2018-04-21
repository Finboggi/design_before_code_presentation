class DeletedPostSpecification
  def initialize(post)
    @post = post
  end

  def satisfied?
    @post.deleted?
  end

  private

  def scope
    PostsFinderService::ForAllUsers.new.deleted.to_scope
  end
end
