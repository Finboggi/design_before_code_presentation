# Суть задачи

Операторы и админы должны иметь возможность скрывать в приложении 
не прокомментированные посты.
Операторы и админы должны иметь возможность восстанавливать скрытые посты.

# Предлагаемое решение

1. В модели `Posts` добавить новое поле `:is_deleted`

```ruby
  add_column :posts, :is_deleted, :boolean, null: false, default: false
```

2. Внести изменение в `CommentRequestsFinderService`

Этот файндер используется для:
* нотификации о необходимости комментирования поста 
  `Notifications::PostCommentingReminderService`
* поиска постов для обычных пользователей `PostsFinderService::ForUser`
* в классе по созданию комментария `PostCommentCreatorService`

Ни один из этих классов не должен находить работать с удаленными постами.

```ruby
  def to_scope
    scope = Comment.joins(:Post)
    scope = apply_comment_type(scope)
    scope = apply_commetators(scope)
    scope = apply_deleted(scope)

    scope
  end
  
  private
  
  def apply_deleted(scope)
    scope.where(posts: {is_deleted: false})
  end
```

Добавлять в публичный интерфейс метод `#with_is_deleted` для управления флагом 
`is_deleted` в скоупе не нужно. В настоящий момент в приложении нет 
необходимости работать с комментариями в удаленных постах.

3. 

Изменить `ListPosts::FinderBuilder`

```ruby
    def build
      apply_status
      apply_deleted

      @finder
    end

    private

    def apply_deleted
      @finder.deleted if @form.deleted
    end
```

4.

Изменить файндер `PostsFinderService::ForAllUsers`, добавить метод
`deleted` и изменить метод `to_scope`.

```ruby
module PostsFinderService
  class ForAllUsers
    def deleted
      @deleted = true
      self
    end
    
    def to_scope
      scope = Post.order(created_at: :desc)
      scope = apply_post_status(scope)
      scope = apply_deleted(scope)

      scope
    end
    
    private
    
    # Удаленные посты не должны показываться, если только не будут специально запрошены.
    def apply_deleted(scope)
      if @deleted
        scope.where(is_deleted: true)
      else
        scope.where(is_deleted: false)
      end
    end
  end
end
```

5. 

Именять файндер `PostsFinderService::ForUser` не нужно, т.к. в нем используется
джойн со скоупом комментариев из `CommentRequestsFinderService`, который уже будет
формироваться с `scope.where(posts: {deleted: false})`

6. 

Создать спецификацию `DeletedPostSpecification`

```ruby
class DeletedPostSpecification
  def initialize(post)
    @post = post
  end

  def satisfied?
    scope.where(id: @post.id).exists?
  end

  private

  def scope
    PostsFinderService::ForAllUsers.new.deleted.to_scope
  end
end
```

7. 

Создать интерактор  `DeletePost`.
Его задача:
* Провести проверку поста: он не должен быть _уже_ удален.
* наложить lock на пост
* Передать пост в сервис `PostDeleterService`

```ruby
class DeletePost
  include Interactor

  around do |interactor|
    context.post.with_lock do
      interactor.call
    end
  end

  def self.callable?(post)
    !DeletedPostSpecification.new(post).satisfied?
  end

  def call
    PostDeleterService.new(context.post).perform
  end
end
```

8.

Создать класс `PostDeleterService`

Его задача:
* Изменить флаг `is_deleted` на `true`
* Записать событие удаления поста в лог событий (пока не реализовано)

9.

Создать интерактор `RestorePost`.
Его задача:
* Провести валидацию поста: должен быть в состоянии `:is_deleted`
* наложить lock на пост
* Передать пост в сервис `PostRestorerService`

```ruby
class RestorePost
  include Interactor

  around do |interactor|
    context.post.with_lock do
      interactor.call
    end
  end

  def self.callable?(post)
    DeletedPostSpecification.new(post).satisfied?
  end

  def call
    PostRestorerService.new(context.post).perform
  end
end
```

10.

Создать сервис `PostRestorerService`.
Его задача:
* Изменить флаг `is_deleted` на `false`
* Записать событие восстановления поста в лог событий (пока не реализовано)

11. Добавить методы в контроллер Posts

```ruby
  def deleted
    respond_with_posts(deleted: true)
  end
```
`#deleted` -- роут для рендара списка удаленных постов для оператора или администратора

12. 

Создать контроллер `PostDeletionsController`

```ruby
class PostDeletionsController < ApplicationController
  load_and_authorize_resource class: 'Post'
  
  def delete
    DeletePost.call(post: @post)
  end

  def restore
    RestorePost.create(post: @post)
  end
end
```

`#delete` и `#restore` -- апи методы для удаления и восстановления удаленных постов

13.

Исправлять абилки для пользователя не нужно:
* на новые действия у обычного пользователя не должно быть прав
* при просмотре удаленного поста из-за изменений в `PostsFinderService::ForUser` обычный пользователь получит 404

14.

Исправить абилки для администратора и оператора, дать возможность: 
* просматривать список удаленных постов


```ruby
# ability/operator.rb | ability/administrator.rb

can %i[delete restore], Post
```

15.

Добавить новый пункт "Удаленные" меню в `app/cells/posts_menu/show.slim`, 
ссылка на `PostsController#deleted`.

16.

Добавить в сервис `PostsCounterService` метод:

```ruby
  def deleted_posts_count
    @finder.deleted.to_scope.count
  end
```

17. 

Класс `Notifications::PostCommentReminderService` не требует изменений.
Требование не отправлять нотификации по удаленным постам будет соблюдаться, т.к.
для нотификации ищутся комментарии через `CommentRequestsFinderService`, а он будет 
искать комментарии только по не удаленным постам



Она будет использоваться в абилках и интеракторах для валидации корректности 
состояния удаляемого или восстанавливаемого поста.

18.

Отмечу, что удаленный пост не будет соответствовать спецификации 
`CommentableByUserPostSpecification` из-за изменений в `PostsFinderService::ForUser`
